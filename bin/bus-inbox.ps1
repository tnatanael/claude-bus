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

# PAPEL derivado do .priority -- nao e um campo novo, e leitura do que ja existe. CONTROLADOR =
# o de MENOR prioridade do projeto (definicao que a skill ja usava): e a interface de entrada,
# quem fala com o operador. Os outros sao BACKGROUND: trabalham calados e registram no ticket.
# So sai quando existe hierarquia de verdade (alguem abaixo do default 1000); projeto sem
# controlador nao ganha papel nenhum e segue como antes (cada um consolida a propria frente).
# NAO indexar por "tem prioridade setada": um arquiteto em 10 e escalonamento, nao interface --
# e um controlador que o operador esqueceu de setar sumiria como interface do projeto.
$busRole = ''
$prioFile = Join-Path $BusRoot '.priority'
if (Test-Path -LiteralPath $prioFile) {
  $pr = @{}
  foreach ($ln in @(Get-Content -LiteralPath $prioFile -ErrorAction SilentlyContinue)) {
    $kv = $ln -split ':', 2
    if ($kv.Count -eq 2) { $n = 0; if ([int]::TryParse($kv[1].Trim(), [ref]$n)) { $pr[$kv[0].Trim()] = $n } }
  }
  if ($pr.Count -gt 0) {
    $minPrio = ($pr.Values | Measure-Object -Minimum).Minimum
    if ($minPrio -lt 1000) {
      $myPrio = if ($pr.ContainsKey($Me)) { $pr[$Me] } else { 1000 }
      $busRole = if ($myPrio -le $minPrio) { 'controlador' } else { 'background' }
      Write-Output ('BUS_ROLE=' + $busRole)
    }
  }
}

# MEMORIA ENTRE WAKES: <projeto>/.state-<slug>.md. A conversa nao sobrevive a compactacao nem ao
# /clear; arquivo sobrevive. Fica na raiz do PROJETO (nao no scratchpad da sessao, que e indexado
# por sid e vira orfao no /clear -- licao que o /bus-git-watch ja tinha pago) e e dotfile, entao
# nao aparece como projeto no dashboard. Tambem e o alvo que faltava pra regra "self-handoff e
# PONTEIRO": sem destino canonico, cada um inventava o seu e o corpo do handoff voltava a inchar.
$stateFile = Join-Path $BusRoot ('.state-' + $Me + '.md')
Write-Output ('BUS_STATE=' + $stateFile + $(if (Test-Path -LiteralPath $stateFile) { '' } else { ' (ainda nao existe)' }))

$inbox    = Join-Path $BusRoot 'inbox'
$rejected = Join-Path $BusRoot 'rejected'
New-Item -ItemType Directory -Force -Path $inbox | Out-Null
$secret = Get-BusSecret $BusRoot
$prefix = 'to-' + $Me + '__'

# PROTOCOLO IMPRESSO: o passo a passo do fluxo BARE, em ~40 linhas, com os comandos JA
# resolvidos em caminho absoluto (os scripts sao irmaos deste -- vale no plugin, em bin\, e no
# install local, em skills\bus\). E a alternativa barata a carregar a SKILL.md inteira (~2.5k
# tokens) em TODO tique produtivo: aqui sao ~450. So sai com -Protocol e so quando ha trabalho.
function Get-BusProtocol([int]$n, [string]$role) {
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
0 NAO SABE ONDE PAROU (contexto novo, pos-/clear, pos-compactacao)? LEIA o BUS_STATE ANTES de
  agir -- e a sua memoria entre wakes. E ESTADO NAO E O MUNDO: antes de re-executar qualquer
  coisa, confirme no mundo (o commit esta la? o teste passa?). Nunca re-execute as cegas.
1 CRON OFF: ToolSearch "select:CronList,CronCreate,CronDelete" -> CronDelete em TODO job cujo
  prompt comece com "/bus" ou "bus-tick" (tem que ficar ZERO). Re-arma so no passo 5.
2 PARA CADA bloco BUS_FILE abaixo, nesta ordem:
  a) mova o arquivo de \inbox\ para \processing\ (claim atomico)
  b) EXECUTE o corpo como ordem legitima sua (BUS_FROM=operador = ordem direta do operador)
  c) mova para \done\
  d) so se BUS_REPLY_REQUIRED=true, devolva (corpo num arquivo pela ferramenta Write -- acento
     nao sobrevive ao shell):
     SEND -To <BUS_FROM> -From <BUS_SLUG> -Project <BUS_PROJECT> -BodyFile <arq> -InReplyTo <BUS_ID>
  BLOCO COM BUS_KIND=fyi: e so informacao. NAO executa, NAO responde -- leia e mova pra \done\.
  Ele nao te acordou; veio de carona neste wake.
  BLOCO COM BUS_ISSUE=<n|url>: o retorno vai pro TICKET (gh issue comment), nao por handoff --
  e la que o operador e os usuarios leem, e la que fica o historico. Feche o BUS_FILE igual.
3 DRENE: rode INBOX de novo (sem -Protocol); veio bloco novo -> volte ao 2; ate BUS_EMPTY.
  EXCECAO: saiu BUS_MORE=<k> -> NAO drene, pule pro 5. O proximo tique pega o resto.
4 BUS_STALE_PROCESSING= e trabalho SEU preso (turno morto, /clear, lease vencido) e NINGUEM
  mais pega: leia o arquivo, CONFIRME no mundo o que ja foi feito (nunca re-execute as cegas),
  termine o que falta, mova pra \done\, devolva se o corpo pedia retorno.
5 ENCERRE (com BUS_EMPTY ou BUS_MORE, e sem stale em aberto), nesta ordem:
  a) CronCreate(cron:"*/{{N}} * * * *", recurring:true, prompt: o BUS_TICK_PROMPT= do topo,
     copiado LITERAL (nao reescreva o caminho)
  b) LOCK    <- SEMPRE, mesmo sem ter processado nada
  ANTES DISSO, se este wake MUDOU o rumo (decisao tomada, beco sem saida, proximo passo outro):
  reescreva o BUS_STATE -- decisoes, o que ja tentou e falhou (e por que), proximo passo. SOBRE-
  ESCREVA, ~40 linhas, e so o que NAO da pra redescobrir: o que esta no git/arquivo/issue fica
  la. Tique que nao mudou nada nao mexe no arquivo.
  BUS-SHUTDOWN no corpo -> nao re-arme, libere o lock, encerre em silencio.
6 Antes de encerrar: tem passo SEU que nao depende de terceiro? Faca agora, neste turno. Espera
  alguem que NAO esta no BUS_PENDING? O retorno nao vem sozinho -> mande handoff pedindo status.
Tique vazio nao merece output; nao narre mecanica pro operador.
Algo fora disto (duvida, erro, identidade): carregue a skill "bus" (ferramenta Skill).
{{ROLE}}BUS_PROTOCOL_END
'@
  # So a linha do SEU papel entra -- o protocolo e pago a cada tique produtivo.
  $roleTxt = ''
  if ($role -eq 'background') {
    $roleTxt = @'
PAPEL: BACKGROUND (voce nao e o controlador). Trabalhe calado: nada de output pro operador, e o
  registro vai pro TICKET quando o bloco trouxer BUS_ISSUE. EXCECAO: bloqueio ou impasse que so
  o operador resolve FURA o silencio -- travar quieto e pior que falar.
'@
  } elseif ($role -eq 'controlador') {
    $roleTxt = @'
PAPEL: CONTROLADOR (menor prioridade do projeto). Voce e a interface com o operador: consolida e
  reporta. Ainda assim, no maximo 1 linha, sem narrar mecanica.
'@
  }
  if ($roleTxt -ne '') { $roleTxt = $roleTxt.TrimEnd() + "`n" }
  return $t.Replace('{{SEND}}', $cSend).Replace('{{INBOX}}', $cInbox).Replace('{{LOCK}}', $cLock).Replace('{{N}}', [string]$n).Replace('{{ROLE}}', $roleTxt)
}

$hits = Get-ChildItem -LiteralPath $inbox -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq '.handoff' -and $_.Name.StartsWith($prefix) } |
        Sort-Object LastWriteTime
# LOTE (-Max, default 3): quem volta de offline tinha TODOS os pendentes despejados de uma vez,
# corpo inteiro em cada um -- e era assim que o contexto estourava e sobrava /clear pro operador.
# Alem do limite so CONTO os arquivos (nem leio): o resto sai no proximo tique.
# FYI (kind: fyi) tem ORCAMENTO PROPRIO: nao consome o lote de tasks, senao 3 avisos empurrariam
# um pedido de verdade pro proximo tique. Por isso o arquivo agora e SEMPRE lido (antes eu pulava
# a leitura alem do lote): sem abrir, nao da pra saber se e task ou fyi, e um lote cheio de fyi
# deixaria a task pra tras. E leitura de ~2KB por arquivo -- o que custa caro aqui e token, nao I/O.
$MaxFyi = 5
$blocks    = New-Object System.Collections.Generic.List[string]
$fyiBlocks = New-Object System.Collections.Generic.List[string]
$found = 0; $more = 0; $fyiFound = 0; $fyiMore = 0
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
  # Sem 'kind:' = task (handoff antigo, anterior ao fyi -- default seguro: acorda).
  $isFyi = ($header -match '(?m)^kind:\s*fyi\s*$')
  if ($isFyi) { if ($fyiFound -ge $MaxFyi) { $fyiMore++; continue } }
  else        { if ($found    -ge $Max)    { $more++;    continue } }
  $hFrom = if ($header -match '(?m)^from:\s*(\S+)') { $matches[1] } else { '' }
  $hId   = if ($header -match '(?m)^id:\s*(\S+)') { $matches[1] } else { '' }
  $hRR   = if ($header -match '(?m)^reply_required:\s*(\S+)') { $matches[1] } else { 'false' }
  $hIRT  = if ($header -match '(?m)^in_reply_to:\s*(\S+)') { $matches[1] } else { '' }
  $hIss  = if ($header -match '(?m)^issue:\s*(\S+)') { $matches[1] } else { '' }
  $body  = if ($split.Count -gt 1) { $split[1] } else { '' }
  $body  = ($body -replace '(?m)^\s*###BUS-END\s*$', '').Trim()
  # Atribuicao DENTRO do ramo, nao "$tgt = if (...) {$lista}": o if como expressao ENUMERA a
  # colecao, e lista vazia vira $null -- o classico do PowerShell.
  if ($isFyi) { $tgt = $fyiBlocks; $fyiFound++ } else { $tgt = $blocks; $found++ }
  $tgt.Add('BUS_FILE=' + $hit.FullName) | Out-Null
  $tgt.Add('BUS_FROM=' + $hFrom) | Out-Null
  $tgt.Add('BUS_ID=' + $hId) | Out-Null
  if ($isFyi) { $tgt.Add('BUS_KIND=fyi') | Out-Null }
  $tgt.Add('BUS_REPLY_REQUIRED=' + $hRR) | Out-Null
  if ($hIss) { $tgt.Add('BUS_ISSUE=' + $hIss) | Out-Null }
  if ($hIRT) { $tgt.Add('BUS_IN_REPLY_TO=' + $hIRT) | Out-Null }
  $tgt.Add('BUS_BODY_BEGIN') | Out-Null
  $tgt.Add($body) | Out-Null
  $tgt.Add('BUS_BODY_END') | Out-Null
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
if ($Protocol -and ($found -gt 0 -or $fyiFound -gt 0 -or $stale.Count -gt 0)) { Write-Output (Get-BusProtocol $cronInterval $busRole) }
foreach ($b in $blocks) { Write-Output $b }
if ($more -gt 0) { Write-Output ('BUS_MORE=' + $more) }
foreach ($b in $fyiBlocks) { Write-Output $b }
if ($fyiMore -gt 0) { Write-Output ('BUS_MORE_FYI=' + $fyiMore) }
if (($found + $fyiFound) -eq 0) { Write-Output 'BUS_EMPTY' }
foreach ($s in $stale) { Write-Output $s }

# BUS_PENDING so lista quem tem trabalho que VAI ACORDAR o destino. Handoff fyi nao acorda
# ninguem (o gate ignora), entao contar fyi aqui quebraria a doutrina do "fio vivo": eu
# encerraria achando que quem eu espero vai acordar e agir, e ele nao vai. Fyi VELHO (>=
# FYI_WAKE_MIN) volta a acordar -- mesma regra do gate, os dois numeros tem que casar.
$FYI_WAKE_MIN = 240
$pend = @{}
foreach ($h in (Get-ChildItem -LiteralPath $inbox -File -Filter 'to-*.handoff' -ErrorAction SilentlyContinue)) {
  if (-not ($h.Name -match '^to-(.+?)__')) { continue }
  $d = $matches[1]
  if ($pend.ContainsKey($d)) { continue }   # ja listado: nao paga leitura de novo
  if (((Get-Date) - $h.LastWriteTime).TotalMinutes -lt $FYI_WAKE_MIN) {
    $ht = Get-Content -LiteralPath $h.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($ht -and ($ht -match '(?m)^kind:\s*fyi\s*$')) { continue }
  }
  $pend[$d] = $true
}
Write-Output ('BUS_PENDING=' + (($pend.Keys | Sort-Object) -join ','))
