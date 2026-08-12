# bus-name.ps1
# Resolve a IDENTIDADE desta sessao (PROJETO + SLUG), indexada por CLAUDE_CODE_SESSION_ID.
# Persiste pra que religacoes do /bus na mesma sessao nao redigitem.
#   -Project <proj> -Set <slug>    -> grava e ecoa. O comando do operador e /bus <PROJETO> <slug>
#                                     (projeto PRIMEIRO, v0.7.0); aqui os params sao nomeados,
#                                     entao a ordem de digitacao nao importa -- o que importa e
#                                     nao trocar o valor de um pelo do outro.
#   (sem -Set)                      -> ecoa o registrado, ou 'NONE'.
# Devolve INVERTED (+HINT) se o slug informado ja e um PROJETO e o projeto informado nao existe
# -- provavel ordem antiga (slug primeiro); nao grava nada nesse caso.
# Saida (quando registrado):
#   PROJECT=<projeto>
#   SLUG=<slug>
# Compat: arquivo antigo de 1 linha (so slug) e lido como projeto 'default'.
# names/ fica SEMPRE na raiz BASE (registro global de quem e quem); o isolamento por
# projeto acontece nas pastas de handoff (inbox/processing/done/rejected por projeto).

param(
  [string]$Set = '',
  [string]$Project = '',
  [int]$Priority = -1,
  [string]$BusRoot = ''
)
# Base: -BusRoot explicito vence; senao CLAUDE_BUS_ROOT; senao %TEMP%\claude-bus. MESMA resolucao
# do bus-inbox/gate/server -- senao a config .bus-cron-interval (e names/seen) iria pra outro lugar.
if ($BusRoot -eq '') { $BusRoot = $env:CLAUDE_BUS_ROOT; if (-not $BusRoot) { $BusRoot = Join-Path $env:TEMP 'claude-bus' } }

$dir = Join-Path $BusRoot 'names'
New-Item -ItemType Directory -Force -Path $dir | Out-Null

$sid = $env:CLAUDE_CODE_SESSION_ID
if (-not $sid) { $sid = 'unknown' }
$f = Join-Path $dir ($sid + '.txt')

# "visto por ultimo": TODA passada do /bus chama o bus-name -> regrava este marcador.
# O dashboard usa o frescor dele pra inferir se o cron da sessao esta REALMENTE armado
# (o cron dispara /bus a cada 5 min, e todo /bus re-arma o cron e passa por aqui).
$seenDir = Join-Path $BusRoot 'seen'
New-Item -ItemType Directory -Force -Path $seenDir | Out-Null
[System.IO.File]::WriteAllText((Join-Path $seenDir $sid), (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false)))

# Intervalo do cron de auto-recheck (GLOBAL, config do dashboard em <base>/.bus-cron-interval).
# Default 5, clamp [1,30]. O modelo arma "*/<esse N> * * * *" -- e o unico numero do cron.
$cronInterval = 5
try { $civ = 0; if ([int]::TryParse((Get-Content -LiteralPath (Join-Path $BusRoot '.bus-cron-interval') -Raw -ErrorAction Stop).Trim(), [ref]$civ) -and $civ -ge 1 -and $civ -le 30) { $cronInterval = $civ } } catch {}

function Emit([string]$proj, [string]$slug) {
  Write-Output ('PROJECT=' + $proj)
  Write-Output ('SLUG=' + $slug)
  Write-Output ('BUS_CRON_INTERVAL=' + $cronInterval)
}

# TRAVA ANTI-INVERSAO: a ordem do comando e /bus <PROJETO> <slug> (v0.7.0; era o inverso ate a
# 0.6.x). Quem teclar a ordem antiga registraria um PROJETO com nome de especialista -- foi assim
# que nasceu um projeto-fantasma na pratica. Sinal forte de inversao: o SLUG informado ja existe
# como PROJETO e o PROJETO informado nao existe. Ai nao grava nada e devolve INVERTED.
$RESERVED = @('names','seen','inbox','processing','done','rejected','presence','state')
function Test-IsProject([string]$n) {
  if ($n -eq '' -or ($RESERVED -contains $n)) { return $false }
  if (Test-Path -LiteralPath (Join-Path $BusRoot $n) -PathType Container) { return $true }
  foreach ($nf in (Get-ChildItem -LiteralPath $dir -Filter '*.txt' -File -ErrorAction SilentlyContinue)) {
    $l = @((Get-Content -LiteralPath $nf.FullName -Raw -Encoding UTF8) -split "`r?`n")
    if ($l.Count -ge 2 -and $l[1].Trim() -ne '' -and $l[0].Trim() -eq $n) { return $true }
  }
  return $false
}

if ($Set -ne '') {
  $proj = $Project.Trim()
  if ($proj -eq '' -or $proj -eq 'default') {
    Write-Output 'NEED_PROJECT'   # projeto e OBRIGATORIO (o 'default' foi removido)
    exit 0
  }
  $slug = $Set.Trim()
  if ((Test-IsProject $slug) -and -not (Test-IsProject $proj)) {
    Write-Output 'INVERTED'
    Write-Output ('HINT=a ordem e /bus <projeto> <slug>; "' + $slug + '" ja e um PROJETO. Voce quis /bus ' + $slug + ' ' + $proj + ' ?')
    exit 0
  }
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
  # LOCK ORFAO DO MESMO SLUG (auto-cura do /clear): se o app trava e o operador da /clear, a
  # sessao ganha um sid NOVO. O .bus-lock ficou gravado com o sid ANTIGO -> a sessao nova nao
  # reconhece o proprio lock, o -Release responde LOCK_NOT_MINE, e o PROJETO INTEIRO fica preso
  # ate o lease de 1h. Como o registro do slug e EXCLUSIVO (a eviccao acima acabou de garantir
  # isso), um lock em nome deste slug so pode ser de uma encarnacao anterior -> libero aqui, no
  # re-arme, que e exatamente quando a sessao se re-apresenta ao BUS.
  $projRootL = if ($proj -eq 'default') { $BusRoot } else { Join-Path $BusRoot $proj }
  $lockL = Join-Path $projRootL '.bus-lock'
  if (Test-Path -LiteralPath $lockL) {
    try {
      $LL = (Get-Content -LiteralPath $lockL -Raw) | ConvertFrom-Json
      if ([string]$LL.slug -eq $slug -and [string]$LL.sid -ne $sid) {
        Remove-Item -LiteralPath $lockL -Force -ErrorAction SilentlyContinue
        $velho = if ($LL.sid) { ([string]$LL.sid).Substring(0, [Math]::Min(8, ([string]$LL.sid).Length)) } else { '?' }
        Write-Output ('LOCK_ORFAO_LIBERADO=' + $velho)   # o modelo reporta isso ao operador
        try { [System.IO.File]::AppendAllText((Join-Path $BusRoot '.bus-gate.log'), ("{0}`tlock-orfao-liberado`t{1}`t{2}`r`n" -f ([datetimeoffset]::Now.ToString('o')), $velho, $slug), $enc) } catch {}
      }
    } catch {}
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
