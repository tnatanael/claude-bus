# bus-inbox.ps1 -Me <slug>
# Leitor ONE-SHOT do inbox: lista os handoffs AUTENTICADOS enderecados a <slug>, do
# mais antigo pro mais novo. Forjados (token errado/ausente) vao pra rejected\ e nao
# saem. Cada handoff valido sai como um bloco:
#   BUS_FILE=<caminho>
#   BUS_BODY_BEGIN
#   <conteudo bruto do handoff>
#   BUS_BODY_END
# Se nao ha nada pendente: BUS_EMPTY. Sem polling, sem background, sem presenca --
# substitui o antigo monitor no modelo pull (o /bus chama isto uma vez e processa).
param(
  [string]$Me = '',
  [string]$Project = '',
  [string]$BusRoot = ''
)
# UTF-8 no stdout: senao o PS 5.1 corrompe acentos do corpo na captura do harness.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# Base global do BUS: names/ e seen/ ficam AQUI (fora do projeto). A raiz do projeto e
# resolvida depois; o agente passa so -Project <nome> e nunca monta caminho com
# %TEMP%/$env:TEMP -- que quebra se rodar via Bash. -BusRoot explicito vence.
$base = $env:CLAUDE_BUS_ROOT
if (-not $base) { $base = Join-Path $env:TEMP 'claude-bus' }
$sid = $env:CLAUDE_CODE_SESSION_ID

# Intervalo do cron (GLOBAL, config do dashboard em <base>/.bus-cron-interval). Default 5,
# clamp [1,30]. O modelo re-arma "*/<esse N> * * * *" no passo 7 -- e o unico numero do cron.
$cronInterval = 5
try { $civ = 0; if ([int]::TryParse((Get-Content -LiteralPath (Join-Path $base '.bus-cron-interval') -Raw -ErrorAction Stop).Trim(), [ref]$civ) -and $civ -ge 1 -and $civ -le 30) { $cronInterval = $civ } } catch {}
Write-Output ('BUS_CRON_INTERVAL=' + $cronInterval)

# IDENTIDADE AUTO-RESOLVIDA: se -Me nao veio, le o registro global names/<sid>
# (linha1=projeto, linha2=slug) -- igual o gate faz -- e ANUNCIA na saida. Assim o
# /bus bare nao precisa de uma chamada separada ao bus-name so pra saber quem e.
if ($Me -eq '') {
  if ($sid) {
    $nf = Join-Path (Join-Path $base 'names') ($sid + '.txt')
    if (Test-Path -LiteralPath $nf) {
      $nl = @(Get-Content -LiteralPath $nf)
      if ($nl.Count -ge 2) { if ($Project -eq '') { $Project = $nl[0].Trim() }; $Me = $nl[1].Trim() }
      elseif ($nl.Count -eq 1) { if ($Project -eq '') { $Project = 'default' }; $Me = $nl[0].Trim() }
    }
  }
  if ($Me -eq '') { Write-Output 'BUS_IDENTITY=NONE'; exit 0 }
  Write-Output ('BUS_SLUG=' + $Me)
  if ($Project -eq '') { Write-Output 'BUS_PROJECT=default' } else { Write-Output ('BUS_PROJECT=' + $Project) }
}

# Raiz do projeto: -BusRoot explicito vence; senao base + projeto (exceto 'default').
if ($BusRoot -eq '') {
  if ($Project -ne '' -and $Project -ne 'default') { $BusRoot = Join-Path $base $Project }
  else { $BusRoot = $base }
}

# Marcador "visto por ultimo" na BASE (global): mantem o "armado" do dashboard fresco a
# cada /bus (mesmo quando a IA pula o bus-name). O cron dispara /bus a cada 5 min.
if ($sid) {
  $seenDir = Join-Path $base 'seen'
  New-Item -ItemType Directory -Force -Path $seenDir | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $seenDir $sid), (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false)))
}

function Get-BusSecret([string]$root) {
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  $path = Join-Path $root '.bus-secret'
  if (-not (Test-Path -LiteralPath $path)) {
    $val = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')
    $tmp = $path + '.' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.tmp'
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmp, $val, $enc)
    try { Move-Item -LiteralPath $tmp -Destination $path -ErrorAction Stop }
    catch { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  }
  return (Get-Content -LiteralPath $path -Raw -Encoding UTF8).Trim()
}

$inbox    = Join-Path $BusRoot 'inbox'
$rejected = Join-Path $BusRoot 'rejected'
New-Item -ItemType Directory -Force -Path $inbox | Out-Null
$secret = Get-BusSecret $BusRoot
$prefix = 'to-' + $Me + '__'

# --- PROFUNDIDADE DA FRENTE (BUS_THREAD_DEPTH) ------------------------------------------
# POR QUE existe: um loop de investigacao entre 2-3 especialistas e INVISIVEL de dentro. Cada
# rodada e localmente correta (acha algo real), mas o AGREGADO vira desperdicio -- num caso real
# 3 especialistas gastaram 106 handoffs (77% do trafego do dia) num defeito de impacto ZERO pro
# usuario, e ninguem percebeu porque nenhuma sessao ve o agregado. Este numero da esse olho.
# COMO: conta quantos handoffs os DOIS slugs (voce e quem enviou, em qualquer direcao) trocaram
# nas ULTIMAS 24H, nas 4 pastas. Le SO O NOME do arquivo (to-/from-/timestamp do id) -- nao abre
# nenhum arquivo, entao nao paga o preco do done/ com milhares de itens.
# O limiar (SS5.1 da SKILL) mora nos dois lugares -- se mudar um, mude o outro.
$THREAD_ALERT_AT = 8
function Get-PairDepthMap([string]$root) {
  $map = @{}
  $cut = (Get-Date).AddHours(-24)
  $ci  = [System.Globalization.CultureInfo]::InvariantCulture
  foreach ($folder in @('inbox','processing','done','rejected')) {
    foreach ($n in (Get-ChildItem -LiteralPath (Join-Path $root $folder) -File -Filter '*.handoff' -ErrorAction SilentlyContinue)) {
      if ($n.Name -notmatch '^to-(.+?)__from-(.+?)__(\d{8}-\d{6})') { continue }
      $a = $matches[1]; $b = $matches[2]; $ts = $matches[3]
      $dt = [datetime]::MinValue
      if (-not [datetime]::TryParseExact($ts, 'yyyyMMdd-HHmmss', $ci, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) { continue }
      if ($dt -lt $cut) { continue }
      $key = (@($a, $b) | Sort-Object) -join '|'
      if ($map.ContainsKey($key)) { $map[$key] = $map[$key] + 1 } else { $map[$key] = 1 }
    }
  }
  return $map
}

$hits = Get-ChildItem -LiteralPath $inbox -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq '.handoff' -and $_.Name.StartsWith($prefix) } |
        Sort-Object LastWriteTime
$pairDepth = @{}
if ($hits) { $pairDepth = Get-PairDepthMap $BusRoot }   # so calcula se ha o que entregar
$found = 0
foreach ($hit in $hits) {
  $raw = Get-Content -LiteralPath $hit.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
  # O end tag confirma que a escrita atomica terminou (nao pega arquivo a meio caminho).
  if (-not ($raw -and ($raw -match '###BUS-END'))) { continue }
  $split  = $raw -split '(?m)^---\s*$', 2
  $header = $split[0]
  $authok = ($header -match '(?m)^auth:\s*(\S+)\s*$') -and ($matches[1] -eq $secret)
  if (-not $authok) {
    New-Item -ItemType Directory -Force -Path $rejected | Out-Null
    Move-Item -LiteralPath $hit.FullName -Destination (Join-Path $rejected $hit.Name) -Force -ErrorAction SilentlyContinue
    continue
  }
  # Entrega SO o que o modelo precisa: quem enviou (from), o id (p/ -InReplyTo), se pede
  # retorno, e o CORPO ja limpo. Descarta auth (token/ruido), o "to" (e voce) e os
  # marcadores ###BUS-START/END -> menos tokens de contexto por leitura, parsing trivial.
  $hFrom = if ($header -match '(?m)^from:\s*(\S+)') { $matches[1] } else { '' }
  $hId   = if ($header -match '(?m)^id:\s*(\S+)') { $matches[1] } else { '' }
  $hRR   = if ($header -match '(?m)^reply_required:\s*(\S+)') { $matches[1] } else { 'false' }
  $hIRT  = if ($header -match '(?m)^in_reply_to:\s*(\S+)') { $matches[1] } else { '' }
  $body  = if ($split.Count -gt 1) { $split[1] } else { '' }
  $body  = ($body -replace '(?m)^\s*###BUS-END\s*$', '').Trim()
  $found++
  Write-Output ('BUS_FILE=' + $hit.FullName)
  Write-Output ('BUS_FROM=' + $hFrom)
  Write-Output ('BUS_ID=' + $hId)
  Write-Output ('BUS_REPLY_REQUIRED=' + $hRR)
  if ($hIRT) { Write-Output ('BUS_IN_REPLY_TO=' + $hIRT) }
  # Quantos handoffs voce e o remetente trocaram nas ultimas 24h (ver bloco acima).
  $pk = (@($Me, $hFrom) | Sort-Object) -join '|'
  $depth = if ($pairDepth.ContainsKey($pk)) { $pairDepth[$pk] } else { 1 }
  Write-Output ('BUS_THREAD_DEPTH=' + $depth)
  # ALERTA so em frente entre ESPECIALISTAS (instrucao do operador nao e frente em loop).
  if ($hFrom -ne 'operador' -and $depth -ge $THREAD_ALERT_AT) {
    Write-Output ('BUS_THREAD_ALERT=' + $hFrom + ':' + $depth + ' -- PARE de aprofundar esta frente e peca alinhamento (SKILL SS5.1)')
  }
  Write-Output 'BUS_BODY_BEGIN'
  Write-Output $body
  Write-Output 'BUS_BODY_END'
}
if ($found -eq 0) { Write-Output 'BUS_EMPTY' }
# INBOX GERAL do projeto: destinos distintos com handoff pendente (o "olhar o inbox geral, nao
# so o seu"). So o nome do arquivo (escrita e atomica -> .handoff = completo), barato. VAZIO =
# bus parado: se voce termina esperando resposta e isto esta vazio, o retorno NAO vem sozinho
# (ninguem te acorda) -> peca o status a quem voce espera (doutrina "fio vivo" da skill).
$pend = @{}
foreach ($h in (Get-ChildItem -LiteralPath $inbox -File -Filter 'to-*.handoff' -ErrorAction SilentlyContinue)) {
  if ($h.Name -match '^to-(.+?)__') { $pend[$matches[1]] = $true }
}
Write-Output ('BUS_PENDING=' + (($pend.Keys | Sort-Object) -join ','))
