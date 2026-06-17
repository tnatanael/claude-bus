# bus-who.ps1
# Lista presenca por DOIS sinais: o heartbeat (presence\<slug>.alive, frescor) E se o
# PROCESSO do monitor esta vivo (sinal "duro", mais confiavel que o carimbo).
param(
  [string]$BusRoot = (Join-Path $env:TEMP 'claude-bus'),
  [int]$FreshSeconds = 120
)

$presence = Join-Path $BusRoot 'presence'
if (-not (Test-Path -LiteralPath $presence)) { Write-Output 'Nenhuma presenca registrada.'; exit 0 }

$rows = Get-ChildItem -LiteralPath $presence -Filter '*.alive' -File -ErrorAction SilentlyContinue | Sort-Object Name
if (-not $rows) { Write-Output 'Nenhuma presenca registrada.'; exit 0 }

# Sinal "duro": processos do monitor vivos (1x, fora do loop).
$procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*bus-monitor.ps1*' })

$now = Get-Date
foreach ($r in $rows) {
  $age = [int](($now - $r.LastWriteTime).TotalSeconds)
  if     ($age -le $FreshSeconds) { $state = 'ATIVO' }
  elseif ($age -le 1800)          { $state = 'ocupado/incerto' }
  else                            { $state = 'OFFLINE' }
  $proc = if ($procs | Where-Object { $_.CommandLine -like ('*-Me ' + $r.BaseName + '*') }) { 'proc:vivo' } else { 'proc:MORTO' }
  Write-Output ('{0,-18} {1,-16} {2,-11} (ultimo beat: {3}s atras)' -f $r.BaseName, $state, $proc, $age)
}
