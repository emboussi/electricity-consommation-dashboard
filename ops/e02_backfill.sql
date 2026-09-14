INSERT INTO monitoring.e02_kpi_horaire (device_id, heure_debut, heure_fin, expected_seconds, observed_seconds, missing_seconds, multiple_seconds, completeness_pct, cycles_complets, cycles_incomplets, current_latest_observed_at, current_freshness_s)
SELECT d.device_id, h, h + interval '1 hour', 3600,
  COALESCE(c.obs, 0), 3600 - COALESCE(c.obs, 0), 0,
  ROUND(100.0 * COALESCE(c.obs, 0) / 3600, 2), COALESCE(c.comp, 0), COALESCE(c.incomp, 0),
  (SELECT MAX(scheduled_at) FROM shelly.p1_collection_cycle WHERE cycle_status='success'),
  (SELECT ROUND(EXTRACT(EPOCH FROM now()-MAX(scheduled_at))::numeric,1) FROM shelly.p1_collection_cycle WHERE cycle_status='success')
FROM generate_series('2026-09-14 08:00+01'::timestamptz, date_trunc('hour', now()) - interval '1 hour', interval '1 hour') h
CROSS JOIN (SELECT DISTINCT device_id FROM shelly.p1_collection_cycle) d
LEFT JOIN LATERAL (
  SELECT COUNT(DISTINCT date_trunc('second', scheduled_at)) obs,
         COUNT(*) FILTER (WHERE present_variables = expected_variables) comp,
         COUNT(*) FILTER (WHERE present_variables < expected_variables) incomp
  FROM shelly.p1_collection_cycle
  WHERE scheduled_at >= h AND scheduled_at < h + interval '1 hour' AND cycle_status = 'success'
) c ON true
ON CONFLICT (device_id, heure_debut) DO NOTHING;
