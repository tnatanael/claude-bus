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
  [int]$Priority = -1,
  [string]$BusRoot = (Join-Path $env:TEMP 'claude-bus')
)

$dir = Join-Path $BusRoot 'names'
New-Item -ItemType Directory -Force -Path $dir | Out-Null

$sid = $env:CLAUDE_CODE_SESSION_ID
if (-not $sid) { $sid = 'unknown' }
$f = Join-Path $dir ($sid + '.txt')

# "visto por ultimo": TODA passada do /bus chama o bus-name -> regrava este marcador.
# O dashboard usa o frescor dele pra inferir se o cron da sessao esta REALMENTE armado
# (o cron dispara /bus de hora em hora, e todo /bus re-arma o cron e passa por aqui).
$seenDir = Join-Path $BusRoot 'seen'
New-Item -ItemType Directory -Force -Path $seenDir | Out-Null
[System.IO.File]::WriteAllText((Join-Path $seenDir $sid), (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false)))

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
  # EVICCAO DE GHOST: este (projeto, slug) agora e DESTA sessao. Apaga qualquer names/<outroSid>
  # com o MESMO (projeto, slug) + o seen dele -- sessao morta re-registrada NAO vira ghost no BUS.
  foreach ($nf in (Get-ChildItem -LiteralPath $dir -Filter '*.txt' -File -ErrorAction SilentlyContinue)) {
    if ($nf.BaseName -eq $sid) { continue }
    $nl = @((Get-Content -LiteralPath $nf.FullName -Raw -Encoding UTF8) -split "`r?`n")
    $np = 'default'; $ns = ''
    if ($nl.Count -ge 2 -and $nl[1].Trim() -ne '') { $np = $nl[0].Trim(); $ns = $nl[1].Trim() }
    elseif ($nl[0].Trim() -ne '') { $ns = $nl[0].Trim() }   # compat: 1 linha = slug, projeto default
    if ($np -eq $proj -and $ns -eq $slug) {
      Remove-Item -LiteralPath $nf.FullName -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath (Join-Path $seenDir $nf.BaseName) -Force -ErrorAction SilentlyContinue
    }
  }
  # -Priority (>=0): upsert "<slug>:<n>" no <projroot>/.priority -- prioridade do gate
  # (default 1000; menor cede mais a vez). Omitido = nao mexe (prioridade persiste).
  if ($Priority -ge 0) {
    $projRoot = if ($proj -eq 'default') { $BusRoot } else { Join-Path $BusRoot $proj }
    New-Item -ItemType Directory -Force -Path $projRoot | Out-Null
    $pf = Join-Path $projRoot '.priority'
    $lines = @()
    if (Test-Path -LiteralPath $pf) { $lines = @(Get-Content -LiteralPath $pf | Where-Object { $_.Trim() -ne '' -and (($_ -split ':',2)[0]).Trim() -ne $slug }) }
    $lines += ($slug + ':' + $Priority)
    [System.IO.File]::WriteAllText($pf, (($lines -join "`n") + "`n"), $enc)
  }
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
