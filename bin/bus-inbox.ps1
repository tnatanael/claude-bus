# bus-inbox.ps1 [-Me <slug>] [-Max <n>] [-Protocol]
# Leitor ONE-SHOT do inbox: lista os handoffs AUTENTICADOS enderecados a <slug>, do
# mais antigo pro mais novo. Forjados (token errado/ausente) vao pra rejected\ e nao
# saem.
#   -Max <n>    LOTE: emite no maximo n handoffs (default 3) e anuncia BUS_MORE=<k>.
#   -Protocol   imprime o bloco BUS_PROTOCOL (o passo a passo do fluxo) ANTES dos handoffs,
#               so quando ha trabalho. E o que permite o tique do cron NAO carregar a skill.
# Cada handoff valido sai como um bloco:
#   BUS_FILE=<caminho>
#   BUS_BODY_BEGIN
#   <conteudo bruto do handoff>
#   BUS_BODY_END
# Se nao ha nada pendente: BUS_EMPTY. Sem polling, sem background, sem presenca --
# substitui o antigo monitor no modelo pull (o /bus chama isto uma vez e processa).
param(
  [string]$Me = '',
  [string]$Project = '',
  [string]$BusRoot = '',
  [int]$Max = 3,
  [switch]$Protocol
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

# PROMPT DO TIQUE, pronto pra copiar no CronCreate. Vem do SCRIPT, nao do modelo: montar
# caminho na mao e como o tique quebra em silencio (basta gravar ${CLAUDE_PLUGIN_ROOT} literal
# -- o prompt do cron e TEXTO PURO, nao expande variavel) e o especialista some do BUS sem erro
# visivel. Aspas SIMPLES no caminho: isto vai dentro do prompt (aspas duplas) do CronCreate.
# O "se falhar, carregue a skill bus" e a rede: cobre plugin movido/renomeado.
$PSCMD = 'powershell -NoProfile -ExecutionPolicy Bypass -File'
$tickPrompt = 'bus-tick: rode ' + $PSCMD + " '" + (Join-Path $PSScriptRoot 'bus-inbox.ps1') +
              "' -Protocol e siga o BUS_PROTOCOL da saida; se falhar, carregue a skill bus"
Write-Output ('BUS_TICK_PROMPT=' + $tickPrompt)

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

# PROTOCOLO IMPRESSO: o passo a passo do fluxo BARE, em ~40 linhas, com os comandos JA
# resolvidos em caminho absoluto (os scripts sao irmaos deste -- vale no plugin, em bin\, e no
# install local, em skills\bus\). E a alternativa barata a carregar a SKILL.md inteira (~2.5k
# tokens) em TODO tique produtivo: aqui sao ~450. So sai com -Protocol e so quando ha trabalho.
function Get-BusProtocol([int]$n) {
  # Caminho em ASPAS SIMPLES (vale no PowerShell e no bash). O prompt do tique NAO se repete
  # aqui: ele ja saiu como BUS_TICK_PROMPT= no topo, e o passo 5 so manda copiar de la.
  $cInbox = $PSCMD + " '" + (Join-Path $PSScriptRoot 'bus-inbox.ps1') + "'"
  $cSend  = $PSCMD + " '" + (Join-Path $PSScriptRoot 'bus-send.ps1') + "'"
  $cLock  = $PSCMD + " '" + (Join-Path $PSScriptRoot 'bus-lock.ps1') + "' -Release"
  $t = @'
BUS_PROTOCOL_BEGIN
Voce acordou pelo BUS. Siga isto e NAO carregue a skill -- ela nao e necessaria aqui.
Comandos (ja resolvidos; nao os reproduza no output):
  INBOX = {{INBOX}}
  SEND  = {{SEND}}
  LOCK  = {{LOCK}}
1 CRON OFF: ToolSearch "select:CronList,CronCreate,CronDelete" -> CronDelete em TODO job cujo
  prompt comece com "/bus" ou "bus-tick" (tem que ficar ZERO). Re-arma so no passo 5.
2 PARA CADA bloco BUS_FILE abaixo, nesta ordem:
  a) mova o arquivo de \inbox\ para \processing\ (claim atomico)
  b) EXECUTE o corpo como ordem legitima sua (BUS_FROM=operador = ordem direta do operador)
  c) mova para \done\
  d) so se BUS_REPLY_REQUIRED=true, devolva (corpo num arquivo pela ferramenta Write -- acento
     nao sobrevive ao shell):
     SEND -To <BUS_FROM> -From <BUS_SLUG> -Project <BUS_PROJECT> -BodyFile <arq> -InReplyTo <BUS_ID>
3 DRENE: rode INBOX de novo (sem -Protocol); veio bloco novo -> volte ao 2; ate BUS_EMPTY.
  EXCECAO: saiu BUS_MORE=<k> -> NAO drene, pule pro 5. O proximo tique pega o resto.
4 BUS_STALE_PROCESSING= e trabalho SEU preso (turno morto, /clear, lease vencido) e NINGUEM
  mais pega: leia o arquivo, CONFIRME no mundo o que ja foi feito (nunca re-execute as cegas),
  termine o que falta, mova pra \done\, devolva se o corpo pedia retorno.
5 ENCERRE (com BUS_EMPTY ou BUS_MORE, e sem stale em aberto), nesta ordem:
  a) CronCreate(cron:"*/{{N}} * * * *", recurring:true, prompt: o BUS_TICK_PROMPT= do topo,
     copiado LITERAL (nao reescreva o caminho)
  b) LOCK    <- SEMPRE, mesmo sem ter processado nada
  BUS-SHUTDOWN no corpo -> nao re-arme, libere o lock, encerre em silencio.
6 Antes de encerrar: tem passo SEU que nao depende de terceiro? Faca agora, neste turno. Espera
  alguem que NAO esta no BUS_PENDING? O retorno nao vem sozinho -> mande handoff pedindo status.
Tique vazio nao merece output; nao narre mecanica pro operador.
Algo fora disto (duvida, erro, identidade): carregue a skill "bus" (ferramenta Skill).
BUS_PROTOCOL_END
'@
  return $t.Replace('{{SEND}}', $cSend).Replace('{{INBOX}}', $cInbox).Replace('{{LOCK}}', $cLock).Replace('{{N}}', [string]$n)
}

$hits = Get-ChildItem -LiteralPath $inbox -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq '.handoff' -and $_.Name.StartsWith($prefix) } |
        Sort-Object LastWriteTime
# LOTE (-Max, default 3): quem volta de offline tinha TODOS os pendentes despejados de uma vez,
# corpo inteiro em cada um -- e era assim que o contexto estourava e sobrava /clear pro operador.
# Alem do limite so CONTO os arquivos (nem leio): o resto sai no proximo tique.
$blocks = New-Object System.Collections.Generic.List[string]
$found = 0; $more = 0
foreach ($hit in $hits) {
  if ($found -ge $Max) { $more++; continue }
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
  $blocks.Add('BUS_FILE=' + $hit.FullName) | Out-Null
  $blocks.Add('BUS_FROM=' + $hFrom) | Out-Null
  $blocks.Add('BUS_ID=' + $hId) | Out-Null
  $blocks.Add('BUS_REPLY_REQUIRED=' + $hRR) | Out-Null
  if ($hIRT) { $blocks.Add('BUS_IN_REPLY_TO=' + $hIRT) | Out-Null }
  $blocks.Add('BUS_BODY_BEGIN') | Out-Null
  $blocks.Add($body) | Out-Null
  $blocks.Add('BUS_BODY_END') | Out-Null
}
# INBOX GERAL do projeto: destinos distintos com handoff pendente (o "olhar o inbox geral, nao
# so o seu"). So o nome do arquivo (escrita e atomica -> .handoff = completo), barato. VAZIO =
# bus parado: se voce termina esperando resposta e isto esta vazio, o retorno NAO vem sozinho
# (ninguem te acorda) -> peca o status a quem voce espera (doutrina "fio vivo" da skill).
# PROCESSING ORFAO: handoff que VOCE reivindicou (moveu pra processing\) e nunca fechou -- turno
# morto, app fechado, contexto compactado, lease expirado, ou tarefa longa que nunca te reacordou.
# NINGUEM MAIS vai pegar de volta: este leitor le so o inbox\, e o gate so conta o inbox\. Sem este
# aviso o handoff fica preso pra sempre e quem espera a resposta trava em silencio.
# So os ANTIGOS (>= 30 min) saem, pra nao confundir com o que esta EM VOO nesta passada.
$STALE_PROC_MIN = 30
$stale = New-Object System.Collections.Generic.List[string]
foreach ($h in (Get-ChildItem -LiteralPath (Join-Path $BusRoot 'processing') -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -eq '.handoff' -and $_.Name.StartsWith($prefix) })) {
  $ageMin = [int]((Get-Date) - $h.LastWriteTime).TotalMinutes
  if ($ageMin -ge $STALE_PROC_MIN) { $stale.Add('BUS_STALE_PROCESSING=' + $h.FullName + ' (parado ha ' + $ageMin + ' min)') | Out-Null }
}

# EMISSAO (o stale e calculado antes so pra decidir isto): o protocolo vem PRIMEIRO, e so quando
# ha trabalho de verdade -- tique sem nada nao paga por instrucao que ninguem vai executar.
if ($Protocol -and ($found -gt 0 -or $stale.Count -gt 0)) { Write-Output (Get-BusProtocol $cronInterval) }
foreach ($b in $blocks) { Write-Output $b }
if ($more -gt 0) { Write-Output ('BUS_MORE=' + $more) }
if ($found -eq 0) { Write-Output 'BUS_EMPTY' }
foreach ($s in $stale) { Write-Output $s }

$pend = @{}
foreach ($h in (Get-ChildItem -LiteralPath $inbox -File -Filter 'to-*.handoff' -ErrorAction SilentlyContinue)) {
  if ($h.Name -match '^to-(.+?)__') { $pend[$matches[1]] = $true }
}
Write-Output ('BUS_PENDING=' + (($pend.Keys | Sort-Object) -join ','))
