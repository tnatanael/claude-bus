# bus-name.ps1
# Resolve o slug do especialista DESTA sessao, indexado por CLAUDE_CODE_SESSION_ID
# (id estavel por sessao). Persiste o nome para que religacoes do /bus na mesma
# sessao nao precisem redigita-lo.
#   -Set <slug>  -> grava o slug desta sessao e ecoa de volta.
#   (sem -Set)   -> ecoa o slug salvo desta sessao, ou 'NONE' se ainda nao definido.

param(
  [string]$Set = '',
  [string]$BusRoot = (Join-Path $env:TEMP 'claude-bus')
)

$dir = Join-Path $BusRoot 'names'
New-Item -ItemType Directory -Force -Path $dir | Out-Null

$sid = $env:CLAUDE_CODE_SESSION_ID
if (-not $sid) { $sid = 'unknown' }
$f = Join-Path $dir ($sid + '.txt')

if ($Set -ne '') {
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($f, $Set.Trim(), $enc)
  Write-Output $Set.Trim()
} elseif (Test-Path -LiteralPath $f) {
  $v = (Get-Content -LiteralPath $f -Raw -Encoding UTF8).Trim()
  if ($v -ne '') { Write-Output $v } else { Write-Output 'NONE' }
} else {
  Write-Output 'NONE'
}
