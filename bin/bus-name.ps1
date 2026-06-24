# bus-name.ps1
# Resolve a IDENTIDADE desta sessao (PROJETO + SLUG), indexada por CLAUDE_CODE_SESSION_ID.
# Persiste pra que religacoes do /bus na mesma sessao nao redigitem.
#   -Set <slug> [-Project <proj>]  -> grava (projeto default = 'default') e ecoa.
#   (sem -Set)                      -> ecoa o registrado, ou 'NONE'.
# Saida (quando registrado):
#   PROJECT=<projeto>
#   SLUG=<slug>
#   BUS_CRON_MINUTE=<0-59>   (minuto aleatorio pro cron de auto-recheck; so usado no 1o arm)
# Compat: arquivo antigo de 1 linha (so slug) e lido como projeto 'default'.
# names/ fica SEMPRE na raiz BASE (registro global de quem e quem); o isolamento por
# projeto acontece nas pastas de handoff (inbox/processing/done/rejected por projeto).

param(
  [string]$Set = '',
  [string]$Project = '',
  [string]$BusRoot = (Join-Path $env:TEMP 'claude-bus')
)

$dir = Join-Path $BusRoot 'names'
New-Item -ItemType Directory -Force -Path $dir | Out-Null

$sid = $env:CLAUDE_CODE_SESSION_ID
if (-not $sid) { $sid = 'unknown' }
$f = Join-Path $dir ($sid + '.txt')

# Minuto do cron DETERMINISTICO por sessao = soma dos bytes do sid mod 60. Estavel
# entre chamadas E identico ao que o dashboard calcula do sid -- assim o countdown
# bate com o minuto realmente armado no cron. (Ainda espalha as sessoes pela hora.)
$cronMin = 0
foreach ($ch in $sid.ToCharArray()) { $cronMin += [int][char]$ch }
$cronMin = $cronMin % 60

function Emit([string]$proj, [string]$slug) {
  Write-Output ('PROJECT=' + $proj)
  Write-Output ('SLUG=' + $slug)
  Write-Output ('BUS_CRON_MINUTE=' + $cronMin)
}

if ($Set -ne '') {
  $proj = $Project.Trim(); if ($proj -eq '') { $proj = 'default' }
  $slug = $Set.Trim()
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($f, $proj + "`n" + $slug, $enc)
  Emit $proj $slug
} elseif (Test-Path -LiteralPath $f) {
  $raw = (Get-Content -LiteralPath $f -Raw -Encoding UTF8)
  $lines = @($raw -split "`r?`n")
  if ($lines.Count -ge 2 -and $lines[1].Trim() -ne '') {
    Emit $lines[0].Trim() $lines[1].Trim()
  } elseif ($lines[0].Trim() -ne '') {
    Emit 'default' $lines[0].Trim()   # compat: 1 linha = so slug, projeto default
  } else {
    Write-Output 'NONE'
  }
} else {
  Write-Output 'NONE'
}
