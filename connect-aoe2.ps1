<#
  connect-aoe2.ps1 - Unirse a nuestro servidor LAN de Age of Empires II: DE (Windows).

  Que hace:
    1. Descarga el launcher de ageLANServer para tu CPU/Windows (una sola vez, cacheado).
    2. Apunta el juego a nuestro servidor LAN y lanza AoE2 DE.

  Ejecutalo como tu usuario normal. Cuando el launcher necesite editar el archivo
  hosts e instalar el certificado del servidor, Windows mostrara un aviso de UAC
  para esos pasos. Todo se revierte automaticamente al salir del juego.

  Requisitos: Windows, Steam abierto con AoE2 DE instalado, y estar en la misma
  LAN (o VPN) que el servidor.

  Uso (PowerShell):
    powershell -ExecutionPolicy Bypass -File .\connect-aoe2.ps1
    powershell -ExecutionPolicy Bypass -File .\connect-aoe2.ps1 192.168.1.50
    $env:SERVER_IP="10.0.0.5"; powershell -ExecutionPolicy Bypass -File .\connect-aoe2.ps1

  O simplemente hace doble-click en connect-aoe2.bat.
#>
param([string]$ServerIp = $env:SERVER_IP)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ===================== EDITAME: direccion por defecto del servidor =====================
if (-not $ServerIp) { $ServerIp = '192.168.0.127' }
# =======================================================================================

$Game         = 'age2'
$UpstreamRepo = 'luskaner/ageLANServer'
$Version      = if ($env:LAUNCHER_VERSION) { $env:LAUNCHER_VERSION } else { 'latest' }
$CacheRoot    = Join-Path $env:LOCALAPPDATA 'agelanserver'

function Info($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "warn: $m" -ForegroundColor Yellow }

# --- Arquitectura y variante de Windows ---
$arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
switch ($arch) {
  'AMD64' { $cpu = 'x86-64' }
  'ARM64' { $cpu = 'arm64' }
  default { throw "Arquitectura de CPU no soportada: $arch" }
}
if ($cpu -eq 'arm64') {
  $winver = 'win11'
} elseif ([Environment]::OSVersion.Version.Major -lt 10) {
  $winver = 'win7'
} else {
  $winver = 'win10'
}
$assetPattern = "_launcher_.*_${winver}_${cpu}\.zip$"

# --- Resolver release ---
$headers = @{ 'Accept' = 'application/vnd.github+json'; 'User-Agent' = 'connect-aoe2' }
if ($Version -eq 'latest') {
  Info "Buscando el ultimo release del launcher..."
  $rel = Invoke-RestMethod "https://api.github.com/repos/$UpstreamRepo/releases/latest" -Headers $headers
} else {
  $rel = Invoke-RestMethod "https://api.github.com/repos/$UpstreamRepo/releases/tags/$Version" -Headers $headers
}
$Tag = $rel.tag_name

$asset = $rel.assets | Where-Object { $_.name -match $assetPattern } | Select-Object -First 1
if (-not $asset) { throw "No hay asset del launcher para Windows ($winver $cpu) en el release $Tag." }

# --- Descargar y extraer si no esta cacheado ---
$dest = Join-Path $CacheRoot "$Tag-$winver-$cpu"
$launcher = Get-ChildItem -Path $dest -Recurse -Filter 'launcher.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $launcher) {
  Info "Descargando launcher $Tag para Windows $winver $cpu..."
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  $zip = Join-Path $env:TEMP "aoe2-launcher-$Tag.zip"
  Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -Headers $headers
  Expand-Archive -Path $zip -DestinationPath $dest -Force
  Remove-Item $zip -Force
  $launcher = Get-ChildItem -Path $dest -Recurse -Filter 'launcher.exe' | Select-Object -First 1
}
if (-not $launcher) { throw "No se encontro launcher.exe dentro del archivo descargado." }

# --- Chequeo de alcance (no fatal) ---
try {
  $tc = New-Object System.Net.Sockets.TcpClient
  $iar = $tc.BeginConnect($ServerIp, 443, $null, $null)
  if (-not $iar.AsyncWaitHandle.WaitOne(5000)) { Warn "No se puede alcanzar ${ServerIp}:443 - estas en la LAN/VPN y el servidor esta prendido?" }
  else { $tc.EndConnect($iar) }
  $tc.Close()
} catch { Warn "No se puede alcanzar ${ServerIp}:443 - estas en la LAN/VPN y el servidor esta prendido?" }

Info "Conectando al servidor LAN de AoE2 DE en $ServerIp ..."
Info "Puede aparecer un aviso de UAC para editar hosts e instalar el certificado."
Set-Location $launcher.DirectoryName
& $launcher.FullName -e $Game -s $ServerIp
exit $LASTEXITCODE
