# bus-who.ps1
# Shows which specialists currently have a LIVE BUS monitor, by reading the
# heartbeat files in presence\. Each running monitor refreshes presence\<slug>.alive
# every couple of seconds, so a fresh timestamp means "listening right now".
#
# Use this instead of guessing presence from list_sessions isRunning: an idle
# session (isRunning=false) can still have its monitor running and pick up handoffs.

param(
  [string]$BusRoot = (Join-Path $env:TEMP 'claude-bus'),
  [int]$FreshSeconds = 120
)

$presence = Join-Path $BusRoot 'presence'
if (-not (Test-Path -LiteralPath $presence)) { Write-Output 'Nenhuma presenca registrada.'; exit 0 }

$rows = Get-ChildItem -LiteralPath $presence -Filter '*.alive' -File -ErrorAction SilentlyContinue | Sort-Object Name
if (-not $rows) { Write-Output 'Nenhuma presenca registrada.'; exit 0 }

$now = Get-Date
foreach ($r in $rows) {
  $age = [int](($now - $r.LastWriteTime).TotalSeconds)
  if     ($age -le $FreshSeconds) { $state = 'ATIVO' }
  elseif ($age -le 1800)          { $state = 'ocupado/incerto' }
  else                            { $state = 'OFFLINE' }
  Write-Output ('{0,-18} {1,-16} (ultimo beat: {2}s atras)' -f $r.BaseName, $state, $age)
}