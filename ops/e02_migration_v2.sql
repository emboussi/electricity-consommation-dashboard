-- E-02 v2.1.0-candidate. STATUS = PREPARED / AUDITED. DEPLOYMENT FORBIDDEN avant cloture gate A-F.
-- Sequence de deploiement (apres cloture) : 1 pg_dump qualifie ; 2 Disable-ScheduledTask E-02 ;
-- 3 verifier aucun run actif ; 4 ce PRECHECK seul ; 5 migration ; 6 runner v2 ; 7 test fenetre connue ;
-- 8 test PANNE connue ; 9 test 10 executions ; 10 verif cardinalite+valeurs ; 11 Enable ; 12 observer 1er run auto ; 13 tag DEPLOYED.
BEGIN;

-- ============ PRECHECK : refuser de travailler si les hypotheses sont fausses ============
DO $pc$
DECLARE v_pk TEXT; v_n INT; v_dup TEXT;
BEGIN
  IF to_regclass('monitoring.e02_kpi_horaire') IS NULL THEN
    RAISE EXCEPTION 'PRECHECK: monitoring.e02_kpi_horaire absente (deja migree ?)';
  END IF;
  SELECT constraint_name INTO v_pk FROM information_schema.table_constraints
   WHERE table_schema='monitoring' AND table_name='e02_kpi_horaire' AND constraint_type='PRIMARY KEY';
  IF v_pk IS NULL THEN RAISE EXCEPTION 'PRECHECK: PK absente sur e02_kpi_horaire'; END IF;
  SELECT COUNT(*) INTO v_n FROM shelly.p1_variable_registry WHERE enabled = true;
  IF v_n = 0 THEN RAISE EXCEPTION 'PRECHECK: registre vide (enabled=true = 0)'; END IF;
  -- Doublon : la contrainte (cycle_id, variable_id) existe-t-elle ? (verdict INVARIANT DEFENSIF)
  SELECT string_agg(constraint_name, ',') INTO v_dup FROM information_schema.table_constraints
   WHERE table_schema='shelly' AND table_name='p1_instantaneous_observation'
     AND constraint_type IN ('PRIMARY KEY','UNIQUE');
  RAISE NOTICE 'PRECHECK OK: pk=%, registre=% variables actives, contraintes obs=%', v_pk, v_n, v_dup;
END $pc$;

-- ============ B1 : lignage historique honnete (jamais version inventee) ============
ALTER TABLE monitoring.e02_kpi_horaire RENAME TO e02_metrics;
ALTER TABLE monitoring.e02_metrics RENAME COLUMN heure_debut TO window_start;
ALTER TABLE monitoring.e02_metrics RENAME COLUMN heure_fin TO window_end;
ALTER TABLE monitoring.e02_metrics RENAME COLUMN calcule_le TO calculated_at;
ALTER TABLE monitoring.e02_metrics ADD COLUMN metric_revision INTEGER;
ALTER TABLE monitoring.e02_metrics ADD COLUMN metric_version_label TEXT;
ALTER TABLE monitoring.e02_metrics ADD COLUMN registry_snapshot_hash TEXT;
ALTER TABLE monitoring.e02_metrics ADD COLUMN last_run_id BIGINT;
UPDATE monitoring.e02_metrics SET metric_revision = 0, metric_version_label = 'legacy-pre-versioned'
 WHERE metric_revision IS NULL;
ALTER TABLE monitoring.e02_metrics ALTER COLUMN metric_revision SET NOT NULL;
ALTER TABLE monitoring.e02_metrics ALTER COLUMN metric_version_label SET NOT NULL;
DO $pk$ DECLARE v_pk TEXT;
BEGIN
  SELECT constraint_name INTO v_pk FROM information_schema.table_constraints
   WHERE table_schema='monitoring' AND table_name='e02_metrics' AND constraint_type='PRIMARY KEY';
  EXECUTE format('ALTER TABLE monitoring.e02_metrics DROP CONSTRAINT %I', v_pk);
END $pk$;
ALTER TABLE monitoring.e02_metrics ADD PRIMARY KEY (device_id, window_start, window_end, metric_revision);

-- ============ Journal des executions (l upsert deduplique n est PAS l idempotence stricte) ============
CREATE TABLE IF NOT EXISTS monitoring.e02_run_log (
  run_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  started_at TIMESTAMPTZ NOT NULL DEFAULT now(), ended_at TIMESTAMPTZ,
  metric_revision INT NOT NULL, window_start TIMESTAMPTZ NOT NULL, window_end TIMESTAMPTZ NOT NULL,
  devices_ok INT, devices_panne INT, result TEXT);

-- ============ B2+B3 : moteur multi-device, panne = cas normal, fraicheur PAR appareil ============
CREATE OR REPLACE FUNCTION monitoring.refresh_e02(p_start TIMESTAMPTZ, p_end TIMESTAMPTZ)
RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE c_rev CONSTANT INT := 210; c_label CONSTANT TEXT := '2.1.0-candidate';
        v_run BIGINT; v_ok INT; v_panne INT; v_hash TEXT;
BEGIN
  INSERT INTO monitoring.e02_run_log (metric_revision, window_start, window_end, result)
  VALUES (c_rev, p_start, p_end, 'RUNNING') RETURNING run_id INTO v_run;
  SELECT md5(string_agg(variable_id, ',' ORDER BY variable_id)) INTO v_hash
    FROM shelly.p1_variable_registry WHERE enabled = true;

  INSERT INTO monitoring.e02_metrics (device_id, window_start, window_end, metric_revision, metric_version_label,
    registry_snapshot_hash, last_run_id, expected_seconds, observed_seconds, missing_seconds, multiple_seconds, completeness_pct,
    gap_p50_s, gap_p95_s, gap_p99_s, gap_max_s, gaps_sup_2s, gaps_sup_5s, gaps_sup_60s,
    cycles_complets, cycles_incomplets, window_last_observed_at, window_end_lag_s,
    current_latest_observed_at, current_freshness_s, calculated_at,
    cycles_conformes_identite, cycles_avec_manquants, cycles_avec_intrus, cycles_avec_doublons)
  WITH devices AS (SELECT DISTINCT device_id FROM shelly.p1_variable_registry WHERE enabled = true),
  ok AS (SELECT c.* FROM shelly.p1_collection_cycle c
         WHERE c.scheduled_at >= p_start AND c.scheduled_at < p_end AND c.cycle_status = 'success'),
  sec AS (SELECT device_id, date_trunc('second', scheduled_at) s, COUNT(*) n FROM ok GROUP BY 1,2),
  gaps AS (SELECT device_id, EXTRACT(EPOCH FROM scheduled_at - LAG(scheduled_at)
           OVER (PARTITION BY device_id ORDER BY scheduled_at)) g FROM ok),
  ref AS (SELECT variable_id FROM shelly.p1_variable_registry WHERE enabled = true),
  obsv AS (SELECT o.cycle_id, o.variable_id FROM shelly.p1_instantaneous_observation o
           JOIN ok ON ok.cycle_id = o.cycle_id WHERE o.is_present = true),
  conf AS (SELECT ok.device_id, ok.cycle_id,
    (SELECT COUNT(*) FROM ref WHERE NOT EXISTS (SELECT 1 FROM obsv WHERE obsv.cycle_id = ok.cycle_id AND obsv.variable_id = ref.variable_id)) manquants,
    (SELECT COUNT(DISTINCT obsv.variable_id) FROM obsv WHERE obsv.cycle_id = ok.cycle_id AND NOT EXISTS (SELECT 1 FROM ref WHERE ref.variable_id = obsv.variable_id)) intrus,
    (SELECT COUNT(*) FROM (SELECT variable_id FROM obsv WHERE obsv.cycle_id = ok.cycle_id GROUP BY 1 HAVING COUNT(*) > 1) dd) doublons
   FROM ok)
  SELECT d.device_id, p_start, p_end, c_rev, c_label, v_hash, v_run,
    EXTRACT(EPOCH FROM p_end - p_start)::int,
    COALESCE((SELECT COUNT(*) FROM sec WHERE sec.device_id = d.device_id), 0),
    EXTRACT(EPOCH FROM p_end - p_start)::int - COALESCE((SELECT COUNT(*) FROM sec WHERE sec.device_id = d.device_id), 0)::int,
    COALESCE((SELECT COUNT(*) FROM sec WHERE sec.device_id = d.device_id AND n > 1), 0),
    ROUND(100.0 * COALESCE((SELECT COUNT(*) FROM sec WHERE sec.device_id = d.device_id), 0) / EXTRACT(EPOCH FROM p_end - p_start), 2),
    (SELECT ROUND(percentile_cont(0.5) WITHIN GROUP (ORDER BY g)::numeric,2) FROM gaps WHERE gaps.device_id = d.device_id AND g IS NOT NULL),
    (SELECT ROUND(percentile_cont(0.95) WITHIN GROUP (ORDER BY g)::numeric,2) FROM gaps WHERE gaps.device_id = d.device_id AND g IS NOT NULL),
    (SELECT ROUND(percentile_cont(0.99) WITHIN GROUP (ORDER BY g)::numeric,2) FROM gaps WHERE gaps.device_id = d.device_id AND g IS NOT NULL),
    (SELECT ROUND(MAX(g)::numeric,2) FROM gaps WHERE gaps.device_id = d.device_id),
    (SELECT COUNT(*) FROM gaps WHERE gaps.device_id = d.device_id AND g > 2),
    (SELECT COUNT(*) FROM gaps WHERE gaps.device_id = d.device_id AND g > 5),
    (SELECT COUNT(*) FROM gaps WHERE gaps.device_id = d.device_id AND g > 60),
    COALESCE((SELECT COUNT(*) FROM ok WHERE ok.device_id = d.device_id AND ok.present_variables = ok.expected_variables), 0),
    COALESCE((SELECT COUNT(*) FROM ok WHERE ok.device_id = d.device_id AND ok.present_variables <> ok.expected_variables), 0),
    (SELECT MAX(ok.scheduled_at) FROM ok WHERE ok.device_id = d.device_id),
    ROUND(EXTRACT(EPOCH FROM p_end - (SELECT MAX(ok.scheduled_at) FROM ok WHERE ok.device_id = d.device_id))::numeric, 1),
    (SELECT MAX(scheduled_at) FROM shelly.p1_collection_cycle pc WHERE pc.cycle_status='success' AND pc.device_id = d.device_id),
    (SELECT ROUND(EXTRACT(EPOCH FROM now() - MAX(scheduled_at))::numeric,1) FROM shelly.p1_collection_cycle pc WHERE pc.cycle_status='success' AND pc.device_id = d.device_id),
    now(),
    COALESCE((SELECT COUNT(*) FROM conf WHERE conf.device_id = d.device_id AND manquants=0 AND intrus=0 AND doublons=0), 0),
    COALESCE((SELECT COUNT(*) FROM conf WHERE conf.device_id = d.device_id AND manquants>0), 0),
    COALESCE((SELECT COUNT(*) FROM conf WHERE conf.device_id = d.device_id AND intrus>0), 0),
    COALESCE((SELECT COUNT(*) FROM conf WHERE conf.device_id = d.device_id AND doublons>0), 0)
  FROM devices d
  ON CONFLICT (device_id, window_start, window_end, metric_revision) DO UPDATE SET
    observed_seconds=EXCLUDED.observed_seconds, missing_seconds=EXCLUDED.missing_seconds,
    multiple_seconds=EXCLUDED.multiple_seconds, completeness_pct=EXCLUDED.completeness_pct,
    gap_p50_s=EXCLUDED.gap_p50_s, gap_p95_s=EXCLUDED.gap_p95_s, gap_p99_s=EXCLUDED.gap_p99_s,
    gap_max_s=EXCLUDED.gap_max_s, gaps_sup_2s=EXCLUDED.gaps_sup_2s, gaps_sup_5s=EXCLUDED.gaps_sup_5s,
    gaps_sup_60s=EXCLUDED.gaps_sup_60s, cycles_complets=EXCLUDED.cycles_complets,
    cycles_incomplets=EXCLUDED.cycles_incomplets, window_last_observed_at=EXCLUDED.window_last_observed_at,
    window_end_lag_s=EXCLUDED.window_end_lag_s, current_latest_observed_at=EXCLUDED.current_latest_observed_at,
    current_freshness_s=EXCLUDED.current_freshness_s, calculated_at=now(),
    registry_snapshot_hash=EXCLUDED.registry_snapshot_hash, last_run_id=EXCLUDED.last_run_id, metric_version_label=EXCLUDED.metric_version_label,
    cycles_conformes_identite=EXCLUDED.cycles_conformes_identite,
    cycles_avec_manquants=EXCLUDED.cycles_avec_manquants,
    cycles_avec_intrus=EXCLUDED.cycles_avec_intrus, cycles_avec_doublons=EXCLUDED.cycles_avec_doublons;

  SELECT COUNT(*) FILTER (WHERE observed_seconds > 0), COUNT(*) FILTER (WHERE observed_seconds = 0)
    INTO v_ok, v_panne FROM monitoring.e02_metrics
   WHERE window_start = p_start AND metric_revision = c_rev;
  UPDATE monitoring.e02_run_log SET ended_at = now(), devices_ok = v_ok, devices_panne = v_panne,
    result = CASE WHEN v_panne = 0 THEN 'OK' WHEN v_ok = 0 THEN 'PANNE_TOTALE' ELSE 'PANNE_PARTIELLE' END
   WHERE run_id = v_run;
  RETURN (SELECT result || ' ' || p_start::text || ' (ok=' || v_ok || ', panne=' || v_panne || ') run=' || v_run
          FROM monitoring.e02_run_log WHERE run_id = v_run);
END $$;

-- ============ B4 : vue explicite, triee sur la revision entiere, jamais sur le texte ============
CREATE OR REPLACE VIEW monitoring.e02_latest AS
SELECT DISTINCT ON (device_id, window_start, window_end)
  device_id, window_start, window_end, metric_revision, metric_version_label, registry_snapshot_hash, last_run_id,
  expected_seconds, observed_seconds, missing_seconds, multiple_seconds, completeness_pct,
  gap_p50_s, gap_p95_s, gap_p99_s, gap_max_s, gaps_sup_2s, gaps_sup_5s, gaps_sup_60s,
  cycles_complets, cycles_incomplets, cycles_conformes_identite,
  cycles_avec_manquants, cycles_avec_intrus, cycles_avec_doublons,
  window_last_observed_at, window_end_lag_s, current_latest_observed_at, current_freshness_s, calculated_at
FROM monitoring.e02_metrics
ORDER BY device_id, window_start, window_end, metric_revision DESC, calculated_at DESC;

COMMIT;

