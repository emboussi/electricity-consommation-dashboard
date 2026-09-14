WITH fen AS (SELECT '2026-09-14 07:00+01'::timestamptz AS h1, '2026-09-14 08:00+01'::timestamptz AS h2),
ok AS (SELECT c.* FROM shelly.p1_collection_cycle c CROSS JOIN fen WHERE c.scheduled_at >= fen.h1 AND c.scheduled_at < fen.h2 AND c.cycle_status = 'success'),
sec AS (SELECT device_id, date_trunc('second', scheduled_at) AS s, COUNT(*) AS n FROM ok GROUP BY 1, 2),
gaps AS (SELECT device_id, EXTRACT(EPOCH FROM scheduled_at - LAG(scheduled_at) OVER (PARTITION BY device_id ORDER BY scheduled_at)) AS g FROM ok)
INSERT INTO monitoring.e02_kpi_horaire
SELECT o.device_id, fen.h1, fen.h2,
  3600,
  (SELECT COUNT(*) FROM sec WHERE sec.device_id = o.device_id),
  3600 - (SELECT COUNT(*) FROM sec WHERE sec.device_id = o.device_id)::int,
  (SELECT COUNT(*) FROM sec WHERE sec.device_id = o.device_id AND n > 1),
  ROUND(100.0 * (SELECT COUNT(*) FROM sec WHERE sec.device_id = o.device_id) / 3600, 2),
  (SELECT ROUND(percentile_cont(0.5) WITHIN GROUP (ORDER BY g)::numeric, 2) FROM gaps WHERE gaps.device_id = o.device_id AND g IS NOT NULL),
  (SELECT ROUND(percentile_cont(0.95) WITHIN GROUP (ORDER BY g)::numeric, 2) FROM gaps WHERE gaps.device_id = o.device_id AND g IS NOT NULL),
  (SELECT ROUND(percentile_cont(0.99) WITHIN GROUP (ORDER BY g)::numeric, 2) FROM gaps WHERE gaps.device_id = o.device_id AND g IS NOT NULL),
  (SELECT ROUND(MAX(g)::numeric, 2) FROM gaps WHERE gaps.device_id = o.device_id),
  (SELECT COUNT(*) FROM gaps WHERE gaps.device_id = o.device_id AND g > 2),
  (SELECT COUNT(*) FROM gaps WHERE gaps.device_id = o.device_id AND g > 5),
  (SELECT COUNT(*) FROM gaps WHERE gaps.device_id = o.device_id AND g > 60),
  COUNT(*) FILTER (WHERE o.present_variables = o.expected_variables),
  COUNT(*) FILTER (WHERE o.present_variables < o.expected_variables),
  MAX(o.scheduled_at),
  ROUND(EXTRACT(EPOCH FROM fen.h2 - MAX(o.scheduled_at))::numeric, 1),
  (SELECT MAX(scheduled_at) FROM shelly.p1_collection_cycle WHERE cycle_status = 'success'),
  (SELECT ROUND(EXTRACT(EPOCH FROM now() - MAX(scheduled_at))::numeric, 1) FROM shelly.p1_collection_cycle WHERE cycle_status = 'success'),
  now()
FROM ok o CROSS JOIN fen
GROUP BY o.device_id, fen.h1, fen.h2
ON CONFLICT (device_id, heure_debut) DO UPDATE SET
  observed_seconds = EXCLUDED.observed_seconds, missing_seconds = EXCLUDED.missing_seconds,
  multiple_seconds = EXCLUDED.multiple_seconds, completeness_pct = EXCLUDED.completeness_pct,
  gap_p50_s = EXCLUDED.gap_p50_s, gap_p95_s = EXCLUDED.gap_p95_s, gap_p99_s = EXCLUDED.gap_p99_s,
  gap_max_s = EXCLUDED.gap_max_s, gaps_sup_2s = EXCLUDED.gaps_sup_2s, gaps_sup_5s = EXCLUDED.gaps_sup_5s,
  gaps_sup_60s = EXCLUDED.gaps_sup_60s, cycles_complets = EXCLUDED.cycles_complets,
  cycles_incomplets = EXCLUDED.cycles_incomplets, window_last_observed_at = EXCLUDED.window_last_observed_at,
  window_end_lag_s = EXCLUDED.window_end_lag_s, current_latest_observed_at = EXCLUDED.current_latest_observed_at,
  current_freshness_s = EXCLUDED.current_freshness_s, calcule_le = now();
