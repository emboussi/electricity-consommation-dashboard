# ops/e02_runner_v2.ps1 - runner du moteur monitoring.refresh_e02(). v2.1.1-candidate
# STATUS = PREPARED / NOT DEPLOYED. Branchement apres gates A-F puis V2.1-1/2/3.
# Contrat : RUN_STATUS (sante du monitoring) distinct de WINDOW_STATUS (sante de la collecte).
$ErrorActionPreference = "Stop"
$LogFile = "C:\Users\omgba.oyono.lionel\Desktop\SHELLY\e02_monitoring.log"
$MetricRevision = 210
$lines = @(); $success = $true; $windowStatus = "UNKNOWN"; $runId = $null

# --- B1 : resolution Docker explicite (le PATH d une tache != PATH du terminal)
$Docker = (Get-Command docker.exe -ErrorAction SilentlyContinue).Source
if (-not $Docker) { $Docker = "C:\Program Files\Docker\Docker\resources\bin\docker.exe" }
if (-not (Test-Path $Docker)) {
  @("==================================================", "E-02 RUN : $([DateTimeOffset]::Now.ToString('o'))",
    "DOCKER_RESOLVED : FAIL (introuvable)", "RUN_STATUS : FAILURE") | Add-Content $LogFile -Encoding UTF8
  exit 1
}

# --- B2 : un seul instant de reference (Africa/Douala = UTC+01 sans DST)
$now = [DateTimeOffset]::Now.ToOffset([TimeSpan]::FromHours(1))
$h2dt = [DateTimeOffset]::new($now.Year, $now.Month, $now.Day, $now.Hour, 0, 0, [TimeSpan]::FromHours(1))
$h1dt = $h2dt.AddHours(-1)
if (($h2dt - $h1dt).TotalSeconds -ne 3600) { throw "Fenetre E-02 invalide : duree differente de 3600 s." }
$h1 = $h1dt.ToString("yyyy-MM-ddTHH:mm:sszzz"); $h2 = $h2dt.ToString("yyyy-MM-ddTHH:mm:sszzz")

$lines += "=================================================="
$lines += "E-02 RUN : $($now.ToString('o'))"
$lines += "RUNNER_VERSION : 2.1.1-candidate"
$lines += "METRIC_REVISION : $MetricRevision"
$lines += "WINDOW : $h1 -> $h2"
$lines += "DOCKER_RESOLVED : $Docker"

function Invoke-Psql([string]$q) {
  $out = & $Docker exec tapo_postgres psql -X -U tapo -d tapo -v ON_ERROR_STOP=1 -qAt -c $q 2>&1
  return @{ exit = $LASTEXITCODE; text = ("$out").Trim() }
}

# --- CHECK 1 : DATABASE
try {
  $r = Invoke-Psql "SELECT 1;"
  if ($r.exit -eq 0 -and $r.text -eq "1") { $lines += "DATABASE : PASS" }
  else { $lines += "DATABASE : FAIL"; $lines += "DATABASE_DETAIL : $($r.text)"; $success = $false }
} catch { $lines += "DATABASE : FAIL"; $lines += "DATABASE_DETAIL : $($_.Exception.Message)"; $success = $false }

# --- CHECK 2 : REFRESH_E02 (statut fenetre != statut run ; B4 : capture du RUN_ID)
if ($success) {
  try {
    $r = Invoke-Psql "SELECT monitoring.refresh_e02('$h1'::timestamptz, '$h2'::timestamptz);"
    if ($r.exit -eq 0 -and $r.text -match '^(OK|PANNE_TOTALE|PANNE_PARTIELLE)\b' ) {
      $windowStatus = $Matches[1]
      if ($r.text -match 'run=(\d+)') { $runId = $Matches[1] }
      $lines += "REFRESH_E02 : PASS"; $lines += "WINDOW_STATUS : $windowStatus"
      $lines += "RUN_ID : $(if ($runId) { $runId } else { 'ABSENT' })"; $lines += "REFRESH_DETAIL : $($r.text)"
      if (-not $runId) { $lines += "REFRESH_E02 : FAIL (run_id absent du retour)"; $success = $false }
    } else { $lines += "REFRESH_E02 : FAIL"; $lines += "REFRESH_DETAIL : $($r.text)"; $success = $false }
  } catch { $lines += "REFRESH_E02 : FAIL"; $lines += "REFRESH_DETAIL : $($_.Exception.Message)"; $success = $false }
} else { $lines += "REFRESH_E02 : SKIPPED (DATABASE FAIL)" }

# --- CHECK 3 : METRICS_WRITTEN (B3 : population contractuelle = celle du moteur ; B4 : correle au RUN_ID)
if ($success) {
  try {
    $exp = Invoke-Psql "SELECT COUNT(DISTINCT device_id) FROM shelly.p1_variable_registry WHERE enabled = true;"
    $got = Invoke-Psql "SELECT COUNT(*) FROM monitoring.e02_metrics WHERE window_start = '$h1'::timestamptz AND window_end = '$h2'::timestamptz AND metric_revision = $MetricRevision AND last_run_id = $runId;"
    if ($exp.exit -eq 0 -and $got.exit -eq 0 -and $exp.text -match '^\d+$' -and $got.text -match '^\d+$' -and [int]$exp.text -ge 1 -and [int]$got.text -eq [int]$exp.text) {
      $lines += "METRICS_WRITTEN : PASS"; $lines += "METRICS_ROWS : $($got.text)/$($exp.text) (run $runId)"
    } else {
      $lines += "METRICS_WRITTEN : FAIL"; $lines += "METRICS_DETAIL : ecrites=$($got.text) attendues=$($exp.text) run=$runId"
      $success = $false
    }
  } catch { $lines += "METRICS_WRITTEN : FAIL"; $lines += "METRICS_DETAIL : $($_.Exception.Message)"; $success = $false }
} else { $lines += "METRICS_WRITTEN : SKIPPED (UPSTREAM FAIL)" }

# --- VERDICT
if ($success) { $lines += "RUN_STATUS : SUCCESS"; $exitCode = 0 } else { $lines += "RUN_STATUS : FAILURE"; $exitCode = 1 }
$lines | Add-Content -Path $LogFile -Encoding UTF8
exit $exitCode
