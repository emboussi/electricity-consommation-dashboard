# E02 : KPI horaires du collecteur P1 - calcule l heure PLEINE precedente. v1.0.0
$log = "C:\Users\omgba.oyono.lionel\Desktop\SHELLY\e02_monitoring.log"
$h1 = (Get-Date).AddHours(-1).ToString("yyyy-MM-dd HH:00+01")
$h2 = (Get-Date).ToString("yyyy-MM-dd HH:00+01")
$sql = Get-Content "C:\Users\omgba.oyono.lionel\Desktop\SHELLY\e02_calc_test.sql" -Raw
$sql = $sql -replace "'2026-09-14 07:00\+01'", "'$h1'" -replace "'2026-09-14 08:00\+01'", "'$h2'"
$out = $sql | docker exec -i tapo_postgres psql -U tapo -d tapo 2>&1
if ($out -match "INSERT 0 1") { Add-Content $log "$(Get-Date -Format u) OK fenetre $h1" }
elseif ($out -match "INSERT 0 0") { Add-Content $log "$(Get-Date -Format u) VIDE fenetre $h1 (aucun cycle - collecte arretee ?)" }
else { Add-Content $log "$(Get-Date -Format u) ECHEC : $($out | Select-Object -Last 1)" }
