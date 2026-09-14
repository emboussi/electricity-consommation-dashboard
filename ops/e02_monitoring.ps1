# E02 : KPI horaires du collecteur P1 - heure PLEINE precedente. v1.1.0
# v1.1.0 : les fenetres sans cycle ecrivent une ligne a zero (la table raconte la panne)
$log = "C:\Users\omgba.oyono.lionel\Desktop\SHELLY\e02_monitoring.log"
$h1 = (Get-Date).AddHours(-1).ToString("yyyy-MM-dd HH:00+01")
$h2 = (Get-Date).ToString("yyyy-MM-dd HH:00+01")
$sql = Get-Content "C:\Users\omgba.oyono.lionel\Desktop\SHELLY\e02_calc_test.sql" -Raw
$sql = $sql -replace "'2026-09-14 07:00\+01'", "'$h1'" -replace "'2026-09-14 08:00\+01'", "'$h2'"
$out = ($sql | docker exec -i tapo_postgres psql -U tapo -d tapo 2>&1) -join " "
if ($out -match "INSERT 0 1") { Add-Content $log "$(Get-Date -Format u) OK fenetre $h1" }
elseif ($out -match "INSERT 0 0") {
  $zero = "INSERT INTO monitoring.e02_kpi_horaire (device_id, heure_debut, heure_fin, expected_seconds, observed_seconds, missing_seconds, multiple_seconds, completeness_pct, cycles_complets, cycles_incomplets, current_latest_observed_at, current_freshness_s) SELECT DISTINCT device_id, '$h1'::timestamptz, '$h2'::timestamptz, 3600, 0, 3600, 0, 0.00, 0, 0, (SELECT MAX(scheduled_at) FROM shelly.p1_collection_cycle WHERE cycle_status='success'), (SELECT ROUND(EXTRACT(EPOCH FROM now()-MAX(scheduled_at))::numeric,1) FROM shelly.p1_collection_cycle WHERE cycle_status='success') FROM shelly.p1_collection_cycle ON CONFLICT (device_id, heure_debut) DO NOTHING;"
  $out2 = ($zero | docker exec -i tapo_postgres psql -U tapo -d tapo 2>&1) -join " "
  Add-Content $log "$(Get-Date -Format u) PANNE fenetre $h1 (0 cycle - ligne zero ecrite : $out2)"
}
else { Add-Content $log "$(Get-Date -Format u) ECHEC : $out" }
