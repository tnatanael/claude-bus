# bus-beat.ps1
# Refresca o heartbeat de presenca DESTA sessao a partir da ATIVIDADE (chamado por um
# hook PostToolUse), nao so pelo monitor. O monitor sai ao entregar um handoff e so
# volta no fim do turno, entao durante o processamento o heartbeat congelaria e o
# dashboard mostraria uma sessao trabalhando como offline. Tocar presence a cada tool
# use mantem a sessao "viva" independente do monitor.
# Resolve o slug por CLAUDE_CODE_SESSION_ID -> names/<sid>.txt. No-op se sem nome.

param(
  [string]$BusRoot = (Join-Path $env:TEMP 'claude-bus')
)

$sid = $env:CLAUDE_CODE_SESSION_ID
if (-not $sid) { exit 0 }

$nameFile = Join-Path (Join-Path $BusRoot 'names') ($sid + '.txt')
if (-not (Test-Path $nameFile)) { exit 0 }
$slug = (Get-Content -Raw $nameFile).Trim()
if (-not $slug) { exit 0 }

$presence = Join-Path $BusRoot 'presence'
New-Item -ItemType Directory -Force -Path $presence | Out-Null
$alive = Join-Path $presence ($slug + '.alive')
if (Test-Path $alive) { (Get-Item $alive).LastWriteTime = Get-Date }
else { New-Item -ItemType File -Path $alive | Out-Null }
