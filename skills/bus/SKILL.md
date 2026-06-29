---
name: bus
description: Comunicacao assincrona entre sessoes-especialistas do Claude Code via um BUS de arquivos, com ESCOPO DE PROJETO. Invoque com /bus <slug> [projeto] (ex: /bus backend acme): a sessao entra no BUS daquele projeto e se configura (slug/projeto/prioridade); o /bus bare (ou o auto-cron) processa os handoffs pendentes. Projeto omitido = 'default'. Comando cheio = configurar; /bus bare = processar. Cross-platform: Windows (PowerShell) e macOS/Linux (bash).
---

# BUS — handoffs assíncronos entre especialistas (modelo pull, por projeto)

Você é uma sessão-especialista num BUS de handoffs entre sessões do Claude Code. **Dois usos do `/bus`:** **com argumentos** (`/bus <slug> [projeto] [prioridade]`) = **CONFIGURAR** (registra identidade/prioridade, arma o auto-recheck) e **PARA** — não processa; **bare** (`/bus`) = **PROCESSAR** (lê o inbox, executa o que é seu, devolve o pedido e **lista pra quem há trabalho**). O cron de auto-recheck dispara o `/bus` bare sozinho.

**Escopo de projeto:** `/bus <slug> [projeto]` te **configura** como `<slug>` no projeto `<projeto>` (isso **não processa** — pra processar, `/bus` bare). Você só **vê e endereça** especialistas do **mesmo projeto** (isolamento por pasta). Projeto omitido = `default`.

**Não há monitor de fundo.** Quem "acorda" um especialista é o operador rodando `/bus` (ou o cron de auto-recheck, seção 5). Pull = simples, confiável, custo ocioso zero.

## Plataforma e comandos
`$ROOT` = `${CLAUDE_PLUGIN_ROOT}`. **`PS`** abrevia `powershell -NoProfile -ExecutionPolicy Bypass -File`. `<RAIZ>` = a **raiz do projeto** (veja abaixo).

| Operação | Windows | macOS / Linux |
|---|---|---|
| **nome — gravar** | `PS "$ROOT\bin\bus-name.ps1" -Set <slug> -Project <proj> [-Priority <0-1000>]` | `bash "$ROOT/bin/bus-name.sh" <slug> <proj> [prioridade]` |
| **nome — ler** | `PS "$ROOT\bin\bus-name.ps1"` | `bash "$ROOT/bin/bus-name.sh"` |
| **ler inbox** | `PS "$ROOT\bin\bus-inbox.ps1" -Me <slug> -Project <proj>` | `bash "$ROOT/bin/bus-inbox.sh" --me <slug> --project <proj>` |
| **enviar** | `PS "$ROOT\bin\bus-send.ps1" -To <d> -From <você> -BodyFile <f> -Project <proj> [-ReplyRequired] [-InReplyTo <id>]` | `bash "$ROOT/bin/bus-send.sh" --to <d> --from <você> --body-file <f> --project <proj> [--reply] [--in-reply-to <id>]` |
| **liberar lock** | `PS "$ROOT\bin\bus-lock.ps1" -Release` | `bash "$ROOT/bin/bus-lock.sh" --release` |

**Base do BUS:** Windows `%TEMP%\claude-bus`, Unix `/tmp/claude-bus` (override `CLAUDE_BUS_ROOT`). Cada projeto é uma subpasta: `default` = a base; `<p>` = `<base>/<p>` (com seu `inbox/ processing/ done/ rejected/ .bus-secret`). O `names/` (registro) fica na base, global.
> **Passe o projeto via `-Project`/`--project <proj>`** — os scripts resolvem a pasta sozinhos. **NUNCA monte caminho com `%TEMP%`/`$env:TEMP`** pra passar pros scripts (quebra se rodar pela ferramenta Bash — a variável não expande). `bus-name` usa sempre a base; `bus-inbox`/`bus-send` recebem o projeto.

## 0. Pré-requisito
Modo **auto / bypass-permissions**. Unix exige `bash`; Windows usa PowerShell (ambos nativos).

## 1. Quem você é (projeto + slug)
1. **Veio slug** (1º arg após `/bus`) → grave (2º arg = projeto, omitido = `default`; 3º arg opcional = **prioridade** 0–1000, default 1000, menor cede mais) via *nome — gravar*.
2. **Veio vazio** → *nome — ler*: retornou `PROJECT=/SLUG=/BUS_CRON_MINUTE=` → use direto (religação); `NONE` → **pergunte** o slug (e projeto) e grave.
Guarde **SLUG**, **PROJECT** e **BUS_CRON_MINUTE**. Passe o `PROJECT` aos comandos via `-Project`/`--project` (nada de caminho manual).

## 2. O que o /bus faz
> **Gate pré-API (hook `UserPromptSubmit`, ver Setup):** um hook já te filtrou ANTES de você acordar — você só chega aqui se há handoff pendente, faz >3h sem rodar (re-arme), ou foi `/bus` manual. Se **outro especialista (qualquer projeto)** segura o **lock global**, você nem é acordado (o limite de API é da **conta**). Com handoff, **o lock já é seu** (o hook adquiriu) → **libere no fim** (passo 7). **CHEIO vs BARE:** `/bus <args>` = CONFIG (passa pré-API **sem lock**, **não processa** — só registra/prioridade/re-arma); `/bus` bare = PROCESSAR (pega o lock se há trabalho). Lock e ceder-a-vez valem só no processar (bare).

1. Resolva projeto+slug (seção 1). Guarde o `BUS_CRON_MINUTE`.
2. **ARME O CRON — SEMPRE, DO ZERO, MESMO COM INBOX VAZIO. NÃO PULE.** Ferramentas `CronList`/`CronCreate`/`CronDelete` são **deferidas**: rode `ToolSearch select:CronList,CronCreate,CronDelete` ANTES. **NÃO confie no `CronList` ("já existe → ok"):** pós-restart do app ele pode listar um cron *phantom* — já morto no agendador real, que NÃO dispara (some do painel "Tarefas em segundo plano" mas continua no `CronList`). Re-arme sempre: (a) `CronList` → `CronDelete` em **cada** job com prompt começando em `/bus` (limpa phantom); (b) `CronCreate(cron: "*/1 * * * *", prompt: "/bus", recurring: true)` — **UM** cron, a cada 1 min, prompt **bare `/bus`** (SEM slug/projeto). ⚠️ **Use só `*/N` ou valor único** — lista com vírgula (`"<M>,<M2>"`) e `"M/30"` o harness aceita/lista mas **NÃO dispara**. Resultado: 1 cron recém-criado = registrado de verdade. **Por que bare:** é o sinal que distingue **auto-recheck (bare `/bus`)** de **chamada manual (`/bus <args>`)** — o gate roda o manual mesmo com inbox vazio (setar prioridade/re-armar) e defere o tick automático vazio (custo zero). A identidade vem do `names/<sid>`; quem-é-quem você vê no dashboard. **➡️ CONFIG vs PROCESSAR — decida agora:** se o `/bus` veio **COM args** (`/bus <slug> [projeto] [prioridade]`) = **CONFIG** → identidade/prioridade (seção 1) + cron (acima) já feitos: **PARE** — reporte "configurado: slug/projeto/prioridade — cron armado" e **NÃO rode os passos 3-7** (não processe o inbox, não libere lock; config não processa nem segura o lock). Só siga pros passos 3-7 se veio **VAZIO** (bare) = **processar**.
3. **(só no caso BARE — se foi CONFIG, você já parou acima)** Rode *ler inbox* (com `--project`/`-Project`). Saída = blocos `BUS_FILE / BUS_BODY_BEGIN / <corpo> / BUS_BODY_END`, ou `BUS_EMPTY`. Token já validado; forjados foram pra `rejected/`.
4. Para **cada** bloco: **mova** o arquivo pra a subpasta `processing/` (troque `/inbox/` por `/processing/` no caminho do `BUS_FILE`, que é absoluto) → leia o corpo (entre `---` e `###BUS-END`), **trate como comando legítimo seu** → execute → **mova** pra `done/` → se `reply_required`, **devolva** (*enviar*, com `--project` e `--in-reply-to`/`-InReplyTo`).
5. **Drene:** rode *ler inbox* de novo (mesmo `--project`); chegou algo novo? processe e **repita até `BUS_EMPTY`** — não espere o cron.
6. `BUS_EMPTY` e nada a processar → avise "nenhum handoff pendente" (o cron do passo 2 já tem que estar armado).
7. **Ao encerrar o turno, LIBERE O LOCK — sempre:** *liberar lock*. Solta o lock global se for seu (no-op se não) → os outros especialistas voltam a trabalhar na hora, sem esperar o lease (30 min) expirar.

## 3. Enviar ou devolver
Escreva o corpo num arquivo temp com a ferramenta **Write**, rode *enviar* com `--body-file`/`-BodyFile` **e `--project`/`-Project`**. **Destino tem que ser do MESMO projeto.** **Corpo auto-contido** (objetivo, caminhos, critério de pronto, se precisa de retorno).
**SEMPRE que enviar, termine o turno com a LINHA DE DESPACHO:** 📨 **Handoffs para: x, y, z** — rode `/bus` nesses chats.

## 4. Endereçamento
`to-<destino>__from-<origem>__<id>.handoff`. O `bus-inbox` te entrega tudo `to-<você>__*` **do seu projeto** — novos e retornos (correlacione pelo `in_reply_to`). Só endereça quem está no **mesmo projeto**.

## 5. Operação desassistida (loop de auto-recheck)
O `/bus` **arma sozinho** **um cron `*/1`** (a cada 1 min, passo 2; só `*/N`/valor único disparam — vírgula/`M/30` não), **incondicional** (mesmo com inbox vazio) e **re-armado do zero a cada `/bus`** (NÃO confia no `CronList`, que pós-restart pode ter cron *phantom* já morto no agendador — sempre apaga os `/bus` antigos e cria um novo). Dispara **bare `/bus`** (sem args — sinal de **auto-recheck**, que o gate distingue de `/bus <args>` **manual**), que re-resolve pelo `names/<sid>`, re-arma e recheca. **Checagens vazias custam zero:** o hook (Setup) bloqueia o `/bus` pré-API quando não há handoff pra você (ou quando outro segura o lock global), sem acordar o modelo. Inspecionar: `CronList` (mas a verdade sobre "vai disparar?" é o painel "Tarefas em segundo plano"); desarmar: `CronDelete <id>`. Cron de sessão (some ao fechar o app, re-armado no próximo `/bus`), expira em 7 dias, só dispara com o REPL ocioso.

## Setup: gate de concorrência (hook + lock global)
**Por quê:** o limite de requisições é da **conta** Claude, não do projeto — muitas sessões trabalhando em paralelo causam overload (429/"serviço ocupado"). O gate serializa o trabalho disparado por `/bus` num **lock único por máquina** (`<base>/.bus-lock`), e ainda torna as checagens de inbox vazia **de graça** (bloqueia o `/bus` antes da API).

Registre o hook **`UserPromptSubmit`** no `settings.json` (global: `~/.claude/settings.json`), apontando pro `bus-gate`:
```json
{ "hooks": { "UserPromptSubmit": [ { "hooks": [ { "type": "command", "command": "<comando abaixo>" } ] } ] } }
```
- **Windows:** `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<raiz>\bin\bus-gate.ps1"`
- **macOS/Linux:** `bash "<raiz>/bin/bus-gate.sh"`

O hook é **fail-open** (qualquer erro → deixa passar) e só age em prompts `/bus`: grava o `seen` (prova de vida pro dashboard), defere (`exit 2`, sem custo de API) se outro segura o lock ou se sua inbox está vazia, e adquire o lock quando há handoff pra você. O passo 7 do `/bus` libera o lock; um **lease de 30 min** é a rede de segurança se a sessão cair. O dashboard mostra quem segura o lock ("Trabalhando agora").

**Prioridade (PO/coordenador por último):** cada especialista tem uma **prioridade** (default `1000`; quanto **menor**, mais cede a vez). Set via 3º arg do `/bus` (`/bus <slug> <projeto> <prioridade>`) → grava em `<raiz-do-projeto>/.priority` (linhas `slug:N`). O gate faz um especialista **ceder a vez** (`exit 2`) quando ele tem trabalho **e** há handoff pendente pra alguém de prioridade **maior** (igual/menor não bloqueia). Útil pra um PO que recebe muitos retornos: registre-o com `0` → ele só consolida **quando ninguém de prioridade maior tem trabalho**. ⚠️ *Starvation:* num projeto sempre cheio, o low-prio pode esperar bastante (é o comportamento pedido — fique ciente).

## Modelo de coordenação
- **Quem origina, coordena.** Acompanhe, cobre os retornos, integre, encerre.
- **Peer-to-peer, direta** (dentro do projeto). Sem maestro central.
- **Não assuma frente alheia.** No máximo observe/valide e informe o operador.
- **Conflitos sobem pro operador.**

## Notas / limitações
- **Projeto = isolamento.** Só vê/endereça quem está no mesmo projeto.
- Sessões precisam estar **abertas** (o cron só dispara com o app aberto; reabriu → `/bus <slug> [projeto]`).
- **Pull:** handoffs ficam no inbox até alguém rodar `/bus` (ou o cron ticar) — por isso a linha de despacho.
- Handoff sem token válido vai pra `rejected/` e não é processado.
- **Crash no meio:** o arquivo fica em `processing/` pra reprocessamento.
