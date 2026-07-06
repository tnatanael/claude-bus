# BUS — referência de mecânica (não injetada)

Este arquivo NÃO é injetado a cada `/bus` — o `SKILL.md` carrega só o núcleo operacional. Aqui fica o **porquê** de cada peça, pra debug/manutenção sem inflar o contexto de toda passada.

## Por que economia de tokens importa aqui
O custo **fixo** de uma passada de PROCESSAMENTO (SKILL injetada + dança de cron + leitura do inbox) domina o corpo marginal de um handoff em ~9:1. Logo, a maior alavanca é **reduzir o número de wakes** (não o tamanho do corpo): um spec completo executado numa passada vale muito mais que a mesma frente fatiada em vários round-trips. Daí a doutrina do `SKILL.md` §3 (um spec/uma passada, sem ack, sem status avulso) e §5 (controlador consolida).

## Gate pré-API (hook `UserPromptSubmit`, `bus-gate.ps1`/`.sh`)
Roda ANTES de o modelo acordar; só age em prompt que começa com `/bus` (o resto passa em `exit 0`). Objetivo: **não estourar o limite da CONTA Claude** (o limite é da conta, não do projeto) e economizar contexto.
- **Lock POR PROJETO** `<projeto>/.bus-lock` (JSON, lease de 30 min): serializa DENTRO do projeto — se **outra** sessão **do mesmo projeto** o segura fresco → `exit 2` (defer, custo zero de API). Projetos diferentes têm locks independentes → **rodam em PARALELO**. Só o BARE `/bus` com trabalho o adquire. (Era global até a v0.6.30; virou por-projeto pra permitir 2+ frentes simultâneas. Tradeoff: o pico de API sobe com o nº de projetos ativos — o limite ainda é da CONTA.)
- **Pausa por projeto** `<projeto>/.bus-paused`: se o marcador existe, o gate defere o processamento (bare `/bus`) daquele projeto (`exit 2`, log `defer-paused`) — **para de pegar handoffs novos SEM interromper** quem já está no meio (o gate só age ANTES de acordar o modelo; a sessão que segura o lock termina o turno). CONFIG (`/bus <args>`) e `/bus-message` NÃO passam por essa checagem (seguem funcionando pausado). O marcador é criado/removido pelo dashboard (`POST /api/pause`, única escrita dele) e tem o mtime refrescado pela manutenção (não é limpo pelo Storage Sense numa pausa longa).
- **Projeto obrigatório** (v0.6.32): o `bus-name -Set` exige `-Project` (sem ele, ou com `default`, devolve `NEED_PROJECT` e o modelo pergunta) — o projeto `default` foi removido. Registros antigos de 1 linha ainda são lidos como `default` (compat), mas nenhum novo é criado assim.
- **CONFIG vs PROCESS:** `/bus <args>` (manual) = config → passa em `exit 0` **sem** o lock (não processa, não serializa); a prioridade do 3º arg é gravada pré-API como rede. Só o **bare** `/bus` processa.
- **Prioridade** (`<projroot>/.priority`, linhas `slug:N`, default 1000, menor cede mais): se EU tenho trabalho E há handoff pra alguém de prioridade MAIOR, o gate me faz **ceder a vez** (`exit 2`). É o que faz o controlador (prioridade baixa) processar por último.
- **Inbox vazio:** seen fresco → `exit 2` (skip grátis); seen >3h → `exit 0` (deixa re-armar o cron pós-restart).
- **Fail-open blindado:** erro inesperado nunca trava um prompt não-`/bus`; mas num `/bus` de sessão conhecida ele ainda tenta adquirir o lock após o erro (se outro segura, defere; senão passa COM o lock) — preserva a serialização mesmo sob falha.
- **Manutenção de estrutura (pré-API, sem trabalho do modelo):** o BUS vive no `%TEMP%`, que o Storage Sense do Windows limpa por idade. O gate garante as pastas e renova o mtime de `.bus-secret`/`names`/`.priority` **só do que já passou de 6h** (evita contenção com ~20 especialistas tocando os mesmos arquivos; toque só mexe no mtime, nunca no conteúdo). Assim o secret não rotaciona e a sessão não perde registro/prioridade.
- **Log forense** `<base>/.bus-gate.log`: `acquire`/`acquire-steal`/`defer-race`/`defer-lock>slug`/`defer-prio>slug`/`failopen-*`/`release`, best-effort, auto-limita ~512 KB.

## Cron de auto-recheck (por que bare, por que desarmar)
- **In-harness:** o "wake" sem o operador é o harness re-invocando a própria sessão (cron/`/loop`). Um processo externo NÃO consegue acordar o chat — por isso não há daemon/monitor; a recuperação é in-harness.
- **Bare `/bus`:** o cron dispara **bare** (sem args) de propósito — é o sinal que distingue **auto-recheck** de **chamada manual** (`/bus <args>` = config). A identidade vem do `names/<sid>`.
- **Re-arma do zero:** pós-restart o `CronList` pode listar um cron *phantom* (some do painel "Tarefas em segundo plano" mas continua no `CronList`) que **não dispara**. Por isso todo `/bus` apaga os `/bus` antigos e cria um novo, em vez de confiar no `CronList`.
- **⚠️ só `*/N` ou valor único disparam** — vírgula (`"<M>,<M2>"`) e `"M/30"` o harness aceita/lista mas **não** dispara.
- **`*/1`:** ticar de 1 em 1 min é barato porque o gate defere tick vazio/bloqueado pré-API (zero API). O jitter do harness dispersa os disparos pela janela do minuto, então o "herd" é menor do que parece.
- **Cron de sessão:** some se o app fechar (re-armado no próximo `/bus`; ou só o cron via `/bus-reload`), expira em 7 dias, só dispara com o REPL ocioso.

### A "dança" desarma/re-arma e a alternativa gate-driven (NÃO implementada)
Hoje a proteção contra auto-interrupção é **do modelo**: o ramo PROCESSAR desarma o cron no início (passo 2) e re-arma no fim (passo 7) — ~5-7 tool calls de overhead por passada. O gate **não** cala o próprio tick da sessão: quando o tick da própria sessão dispara e ela ainda segura o lock, o gate re-adquire esse lock e a acorda (o defer-por-lock só barra o tick de OUTRA sessão).

**Por que NÃO mover isso pro gate (ideia DESCARTADA):** deferir o próprio tick no gate deixaria o cron **permanente** (nunca re-criado). Na prática, um cron loop permanente **degrada em phantom depois de algumas horas** — para de disparar / some sozinho / acumula e perde referência (observado em operação real; causa exata desconhecida). **Re-armar do zero a cada processamento** (desarma no início do passo 2, cria de novo no passo 7) é o que mantém o loop **fresco** — por isso é load-bearing, não é só anti-interrupção. Logo a dança do cron **fica**. O que dá pra otimizar é tirar do modelo o trabalho **mecânico** (mover handoffs inbox→processing→done, resolver identidade) via script — não o ciclo do cron.

## /bus-message (instrução do operador, sem acordar o modelo)
`/bus-message <texto>` é interceptado pelo **próprio gate** (hook `UserPromptSubmit`): ele resolve a identidade da sessão (`names/<sid>`), escreve um handoff `operador→seu-slug` no inbox do projeto (com o token, mesma lógica do bus-send) e **bloqueia o prompt (`exit 2`)** — o modelo **NÃO acorda**, custo ZERO de token. O especialista processa a instrução no próximo `/bus` (tick do cron ou manual), como qualquer handoff (`BUS_FROM=operador`, sem retorno). Como `/bus-message` não casa o regex `^/bus(\s|$)`, não interfere no gating normal do `/bus`. Há uma skill `bus-message` de **fallback**: se o hook não estiver instalado, o prompt chega ao modelo e a skill escreve o handoff via bus-send (custo pequeno, mas funciona).

## Autenticação e escrita
- Cada handoff carrega um token `auth:` (do `.bus-secret` compartilhado do projeto). O `bus-inbox` valida e manda forjados pra `rejected\` antes de te entregar; o `bus-send` injeta o token. Protege contra injeção **casual** via `%TEMP%`, não contra malware que leia o disco.
- Escrita atômica (temp + rename) pro leitor nunca pegar arquivo pela metade; o `###BUS-END` confirma escrita completa. Corpo em UTF-8 **sem BOM** (preserva acentos).

## Contrato do `bus-inbox` (saída enxuta)
O `bus-inbox` entrega ao modelo só `BUS_FROM`/`BUS_ID`/`BUS_REPLY_REQUIRED`/(`BUS_IN_REPLY_TO`) + o **corpo limpo** entre `BUS_BODY_BEGIN`/`END`. Descarta o `auth:` (token/ruído), o `to:` (é o próprio) e os marcadores `###BUS-START/END` — menos tokens por leitura e parsing trivial (o modelo não extrai corpo de raw). O `split` é com limite 2, então um `---` **dentro** do corpo não quebra o parsing.

**Identidade auto-resolvida:** chamado **sem `-Me`**, o `bus-inbox` lê o `names/<sid>` (linha1=projeto, linha2=slug) — como o gate faz — e abre a saída com `BUS_SLUG=`/`BUS_PROJECT=` (ou `BUS_IDENTITY=NONE` se a sessão nunca se registrou). Assim o `/bus` **bare não chama o `bus-name`** só pra se identificar — uma chamada a menos por passada. Com `-Me` explícito o comportamento é o de antes (retrocompat). O `seen` (prova de vida do dashboard) segue sendo gravado pelo `bus-inbox` a cada chamada, independente do `bus-name`. O `BUS_CRON_MINUTE` que o `bus-name` emite virou **vestigial** (o cron é `*/1` fixo, sem spread por-sid) — o bare não precisa mais dele.

## `.ps1` sem acento
Os scripts `.ps1` são escritos **sem acento** no código/comentários: o PowerShell 5.1 corrompe acentos em arquivo salvo sem BOM (a ferramenta Write salva sem BOM). Conteúdo com acento vai só nos **corpos** de handoff (escritos via Write, lidos como UTF-8 sem BOM).
