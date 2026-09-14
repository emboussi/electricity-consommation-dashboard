WITH fen AS (SELECT '2026-09-14 07:00+01'::timestamptz h1, '2026-09-14 08:00+01'::timestamptz h2),
-- CHEMIN INDEPENDANT : depuis les observations, on reconstruit les cycles et leurs contenus
cyc AS (SELECT c.cycle_id, c.device_id, c.scheduled_at
        FROM shelly.p1_collection_cycle c CROSS JOIN fen
        WHERE c.scheduled_at >= fen.h1 AND c.scheduled_at < fen.h2 AND c.cycle_status = 'success'),
obs_par_cycle AS (SELECT cyc.cycle_id, cyc.device_id, cyc.scheduled_at,
        COUNT(DISTINCT o.variable_id) FILTER (WHERE o.is_present) AS vars_reelles
        FROM cyc LEFT JOIN shelly.p1_instantaneous_observation o ON o.cycle_id = cyc.cycle_id
        GROUP BY 1, 2, 3),
ref_n AS (SELECT COUNT(*) n FROM shelly.p1_variable_registry WHERE enabled = true),
contre AS (SELECT device_id,
        COUNT(*) AS cycle_count,
        COUNT(DISTINCT date_trunc('second', scheduled_at)) AS observed_seconds,
        COUNT(*) FILTER (WHERE vars_reelles = (SELECT n FROM ref_n)) AS cycles_complets_reels,
        COUNT(*) FILTER (WHERE vars_reelles <> (SELECT n FROM ref_n)) AS cycles_incomplets_reels
        FROM obs_par_cycle GROUP BY 1),
e02 AS (SELECT * FROM monitoring.e02_kpi_horaire WHERE heure_debut = '2026-09-14 07:00+01'::timestamptz)
SELECT v.controle, v.e02_valeur, v.contre_calcul,
       CASE WHEN v.e02_valeur = v.contre_calcul THEN 'PASS' ELSE 'ECART' END AS verdict
FROM e02, contre c, (VALUES
  ('observed_seconds',            (SELECT observed_seconds FROM e02),            (SELECT observed_seconds FROM contre)),
  ('cycles_complets (vs observations reelles)', (SELECT cycles_complets FROM e02), (SELECT cycles_complets_reels FROM contre)),
  ('cycles_incomplets',           (SELECT cycles_incomplets FROM e02),           (SELECT cycles_incomplets_reels FROM contre)),
  ('conformes_identite = cycle_count', (SELECT cycles_conformes_identite FROM e02), (SELECT cycle_count FROM contre)),
  ('IDENTITE expected = observed + missing', (SELECT expected_seconds FROM e02), (SELECT observed_seconds + missing_seconds FROM e02)),
  ('IDENTITE completeness = observed/expected', (SELECT ROUND(completeness_pct * 36, 0)::int FROM e02), (SELECT observed_seconds FROM e02)),
  ('IDENTITE conformes+manquants+intrus+doublons >= cycles', (SELECT cycle_count FROM contre), (SELECT cycles_conformes_identite + cycles_avec_manquants + cycles_avec_intrus + cycles_avec_doublons FROM e02))
) AS v(controle, e02_valeur, contre_calcul)
LIMIT 7;
