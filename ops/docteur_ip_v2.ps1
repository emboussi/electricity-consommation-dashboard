[CmdletBinding()]
param(
    [string]$ProjetDir = "",
    [string]$NomMdns   = "shellypro3em63-a4f00fccaf68.local",
    [string]$MacAttendue = "A4F00FCCAF68",
    [int]$TimeoutScanMs = 600
)

$ErrorActionPreference = "Stop"

if (-not $ProjetDir) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $candidat = if ((Split-Path -Leaf $scriptDir) -eq "ops") { Split-Path -Parent $scriptDir } else { $scriptDir }
    $ProjetDir = $candidat
}
$EnvPath = Join-Path $ProjetDir ".env"
$LogDir  = Join-Path $ProjetDir "ops"
$LogPath = Join-Path $LogDir "docteur_ip.log"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }

function Journal {
    param([string]$Niveau, [string]$Message)
    $ligne = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Niveau, $Message
    Add-Content -Path $LogPath -Value $ligne
    Write-Verbose $ligne
}

if (-not (Test-Path $EnvPath)) {
    Journal "ERREUR" "Fichier .env introuvable : $EnvPath - abandon."
    exit 1
}
$ligneEnv = (Get-Content $EnvPath | Select-String '^SHELLY_IP=').Line
$ipActuelle = if ($ligneEnv) { $ligneEnv -replace '^SHELLY_IP=', '' } else { "" }

$ipTrouvee = $null
try {
    $res = Resolve-DnsName -Name $NomMdns -Type A -ErrorAction Stop
    $ipTrouvee = ($res | Where-Object { $_.Type -eq "A" } | Select-Object -First 1).IPAddress
    if ($ipTrouvee) { Journal "INFO" "mDNS OK : $NomMdns -> $ipTrouvee" }
}
catch {
    Journal "AVERT" "mDNS sans reponse ($NomMdns) - bascule sur le scan."
}

function Confirme-Identite {
    param([string]$Ip)
    try {
        $info = Invoke-RestMethod "http://$Ip/rpc/Shelly.GetDeviceInfo" -DisableKeepAlive -TimeoutSec 3
        return ($info.mac -replace ':', '') -ieq $MacAttendue
    } catch { return $false }
}

if (-not $ipTrouvee) {
    $prefixes = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" -and $_.IPAddress -notlike "172.*" } |
        ForEach-Object { ($_.IPAddress -split '\.')[0..2] -join '.' } |
        Sort-Object -Unique

    foreach ($p in $prefixes) {
        Journal "INFO" "Scan du sous-reseau $p.0/24 (port 80)..."
        $candidats = 1..254 | ForEach-Object {
            $t = "$p.$_"
            if ((New-Object Net.Sockets.TcpClient).ConnectAsync($t, 80).Wait($TimeoutScanMs)) { $t }
        }
        foreach ($c in $candidats) {
            if (Confirme-Identite $c) {
                $ipTrouvee = $c
                Journal "INFO" "Scan OK : appareil confirme (MAC $MacAttendue) a $ipTrouvee"
                break
            }
        }
        if ($ipTrouvee) { break }
    }
}

if (-not $ipTrouvee) {
    Journal "ERREUR" "Appareil introuvable (ni mDNS ni scan) - nouvel essai au prochain passage."
    exit 2
}

if (-not (Confirme-Identite $ipTrouvee)) {
    Journal "ERREUR" "L'IP $ipTrouvee ne repond pas ou n'est pas le bon appareil - pas de modification."
    exit 3
}

if ($ipTrouvee -eq $ipActuelle) {
    Journal "OK" "IP inchangee ($ipActuelle) - rien a faire."
    exit 0
}

Journal "ACTION" "Rotation detectee : $ipActuelle -> $ipTrouvee - mise a jour du .env."
if ($ligneEnv) {
    (Get-Content $EnvPath) -replace '^SHELLY_IP=.*', "SHELLY_IP=$ipTrouvee" | Set-Content $EnvPath
} else {
    Add-Content $EnvPath "SHELLY_IP=$ipTrouvee"
}

try {
    docker info 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "demon indisponible" }
    Push-Location $ProjetDir
    docker compose up -d 2>&1 | Out-Null
    Pop-Location
    Journal "OK" "Stack relancee avec SHELLY_IP=$ipTrouvee."
}
catch {
    Journal "AVERT" "Docker indisponible - .env corrige, la stack prendra la nouvelle IP au prochain demarrage."
}
exit 0
