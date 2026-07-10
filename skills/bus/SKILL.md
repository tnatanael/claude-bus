---
name: bus
description: Comunicacao assincrona entre sessoes-especialistas do Claude Code via um BUS de arquivos, com ESCOPO DE PROJETO. /bus <slug> <projeto> [prioridade] CONFIGURA a sessao (identidade/prioridade/auto-recheck); /bus bare (ou o auto-cron) PROCESSA os handoffs pendentes. O projeto e OBRIGATORIO. Comando cheio = configurar; /bus bare = processar. Cross-platform: Windows (PowerShell) e macOS/Linux (bash).
---

# BUS — handoffs assíncronos entre especialistas (por projeto)

Você é uma sessão-especialista num BUS de handoffs entre sessões do Claude Code. **Dois usos do `/bus`:**
- **`/bus <slug> <projeto> [prioridade]`** (com args) = **CONFIGURAR** (registra identidade/prioridade, arma o auto-recheck) e **PARA** — não processa.
- **`/bus`** (bare) = **PROCESSAR** (lê o inbox, executa o que é seu, responde). O cron de auto-recheck dispara o bare sozinho e **entrega os handoffs aos destinos**.

**Escopo de projeto:** o **projeto é OBRIGATÓRIO** (o `default` foi removido). Cada projeto é isolado por pasta; você só **vê e endereça** especialistas do **mesmo projeto**. A mecânica interna (gate, lock, cron, auth, `/bus-message`, pausa) está em **`REFERENCE.md`** — não precisa relê-la pra operar.

## Plataforma e comandos
`$ROOT` = `${CLAUDE_PLUGIN_ROOT}`. **`PS`** abrevia `powershell -NoProfile -ExecutionPolicy Bypass -File`.

| Operação | Windows | macOS / Linux |
|---|---|---|
| **nome — gravar** | `PS "$ROOT\bin\bus-name.ps1" -Set <slug> -Project <proj> [-Priority <0-1000>]` | `bash "$ROOT/bin/bus-name.sh" <slug> <proj> [prioridade]` |
| **ler inbox** (auto-resolve) | `PS "$ROOT\bin\bus-inbox.ps1"` | `bash "$ROOT/bin/bus-inbox.sh"` |
| **enviar** | `PS "$ROOT\bin\bus-send.ps1" -To <d> -From <você> -BodyFile <f> -Project <proj> [-ReplyRequired] [-InReplyTo <id>]` | `bash "$ROOT/bin/bus-send.sh" --to <d> --from <você> --body-file <f> --project <proj> [--reply] [--in-reply-to <id>]` |
| **liberar lock** | `PS "$ROOT\bin\bus-lock.ps1" -Release` | `bash "$ROOT/bin/bus-lock.sh" --release` |

**Base do BUS:** Windows `%TEMP%\claude-bus`, Unix `/tmp/claude-bus` (override `CLAUDE_BUS_ROOT`). Cada projeto é a subpasta `<base>/<projeto>` (com seu `inbox/ processing/ done/ rejected/ .bus-secret`). O `names/` (registro) fica na base, global.
> **Passe o projeto via `-Project`/`--project`** — os scripts resolvem a pasta sozinhos. **NUNCA monte caminho com `%TEMP%`/`$env:TEMP`** (quebra se rodar pela ferramenta Bash — a variável não expande).

## 0. Pré-requisito
Modo **auto / bypass-permissions**. Unix exige `bash`; Windows usa PowerShell (ambos nativos).

## 1. Quem você é (projeto + slug)
- **`/bus` COM args (CONFIG)** → grave via *nome — gravar*. O **projeto é OBRIGATÓRIO** (2º arg); 3º arg opcional = **prioridade** (0–1000, default 1000, menor cede mais). Registrar **reivindica** o slug (apaga sid antigo do mesmo slug+projeto — sem ghost). Se o operador não deu o projeto, **pergunte**. Se o `bus-name` responder `NEED_PROJECT` (faltou o projeto ou veio `default`), pergunte o projeto e repita.
- **`/bus` BARE (PROCESSAR)** → **não resolva identidade aqui**: o `bus-inbox` (passo 3) a resolve sozinho e devolve `BUS_SLUG=`/`BUS_PROJECT=` no topo. Se devolver `BUS_IDENTITY=NONE` (sessão nunca registrada), **pergunte** o slug + projeto, registre (CONFIG) e pare.

## 2. O que o /bus faz
> **Gate pré-API (hook `UserPromptSubmit`, ver Setup):** um hook já te filtrou ANTES de você acordar — você só chega aqui se há handoff pendente, faz >3h sem rodar (re-arme), ou foi `/bus` manual. O lock é **POR PROJETO**: se outro especialista **do seu projeto** está trabalhando, você defere; projetos **diferentes** rodam em **paralelo**. Com handoff, **o lock (do seu projeto) já é seu** → **libere no fim** (passo 7). **CHEIO vs BARE:** `/bus <args>` = CONFIG (passa pré-API **sem lock**, não processa); `/bus` bare = PROCESSAR.

1. Identidade: **CONFIG** já registrou (seção 1); **BARE** resolve no passo 3 (o `bus-inbox` devolve `BUS_SLUG`/`BUS_PROJECT`) — sem chamada ao `bus-name`.
2. **CRON — DESARMA no início, RE-ARMA no fim.** `CronList`/`CronCreate`/`CronDelete` são deferidas: rode `ToolSearch select:CronList,CronCreate,CronDelete` ANTES. **NÃO confie no `CronList`** (pós-restart lista *phantom* já morto que NÃO dispara). **DESARMAR** = `CronList`→`CronDelete` em **CADA** job com prompt começando em `/bus` (fica **ZERO** `/bus` agendado). **ARMAR** = `CronCreate(cron:"*/1 * * * *", prompt:"/bus", recurring:true)` — 1 cron, **bare `/bus`** (⚠️ só `*/N`/valor único disparam; vírgula/`M/30` **não**). **Por tipo:** **CONFIG** (com args) → registre (seção 1), **DESARME + ARME** e **PARE** (reporte "configurado: slug/projeto/prioridade"; não rode 3-7). **PROCESSAR** (bare) → **DESARME agora** (só `CronList`→`CronDelete`), siga 3-7 e **RE-ARME só no passo 7**. Não pule o desarmar — é o que evita ser re-acordado no meio do trabalho.
3. **(só no BARE)** Rode *ler inbox* (**sem `-Me`/`--me` — auto-resolve**). A saída abre com a identidade e depois os blocos, do mais antigo pro mais novo (ou `BUS_EMPTY`; ou `BUS_IDENTITY=NONE` → volte à seção 1):
   ```
   BUS_SLUG=<seu slug>          (guarde — é o -From dos retornos)
   BUS_PROJECT=<seu projeto>    (guarde — é o -Project dos moves/retornos)
   BUS_FILE=<caminho absoluto>
   BUS_FROM=<quem enviou — a quem você responde>
   BUS_ID=<id — use no -InReplyTo>
   BUS_REPLY_REQUIRED=<true|false>
   BUS_IN_REPLY_TO=<id>         (só se for um retorno)
   BUS_BODY_BEGIN
   <corpo, já limpo — sem header nem marcadores>
   BUS_BODY_END
   ```
4. Para **cada** bloco: **mova** o `BUS_FILE` pra `processing/` (troque `/inbox/` por `/processing/`) → **execute** o corpo como comando legítimo seu (`BUS_FROM=operador` = instrução direta do operador via `/bus-message` — trate como ordem dele) → **mova** pra `done/` → se `BUS_REPLY_REQUIRED=true`, **devolva** (*enviar*: `-To BUS_FROM -From BUS_SLUG -Project BUS_PROJECT -InReplyTo BUS_ID`).
   - ⚡ **Tarefa longa (>2 min) em background:** dispare-a e faça o **passo 7 JÁ** (re-arme o cron + libere o lock) — background não usa API, segurar o lock só atrasa os outros. O handoff fica em `processing/`; finalize (→`done/` + retorno) quando a tarefa concluir e te re-acordar.
5. **Drene:** rode *ler inbox* de novo (auto-resolve). Chegou algo novo? Volte ao passo 4. **Repita até `BUS_EMPTY`.**
6. `BUS_EMPTY`: **antes de encerrar, confirme que você não tem trabalho PRÓPRIO pendente** (passos do seu plano, handoffs que ainda precisa enviar) — se tem, **faça agora neste turno** (o cron **não** te retoma pra continuar seu plano — veja *Mantenha o fio vivo*). Só quando estiver **sem ação possível**: siga direto pro passo 7, **sem anunciar nada**.
7. **Ao encerrar (PROCESSAR):** (1) **RE-ARME o cron** (`CronList`→`CronDelete` nos `/bus`, depois `CronCreate("*/1 * * * *", "/bus", recurring)`). (2) **LIBERE O LOCK — sempre** (mesmo sem processar): *liberar lock* (libera o do seu projeto; no-op se não for seu).

## 3. Enviar ou devolver
Escreva o corpo num arquivo temp com a ferramenta **Write**, rode *enviar* com `--body-file`/`-BodyFile` **e `--project`/`-Project`**. Destino do **mesmo projeto**.

**Não anuncie despacho.** O cron do destino (a cada 1 min) pega o handoff sozinho e o dashboard mostra os pendentes + quem está offline — a antiga "linha de despacho" (📨 rode `/bus` lá) virou ruído. Se um destino estiver **fechado**, o handoff só espera no inbox dele (visível no dashboard) até reabrir.

### Como escrever handoffs econômicos SEM perder precisão
O destino **não tem seu contexto** — o corpo tem que ser **completo e preciso**: objetivo, arquivos/caminhos, constraints e critério de "pronto". **Precisão vem primeiro.** O que cortar é o **desperdício**:
- **Um spec completo, uma passada.** Se prevê os próximos 2-3 handoffs pro mesmo destino, **junte num spec só** (cada round-trip acorda o outro do zero — caro).
- **`-ReplyRequired` só pra receber DADO/decisão.** "Confirma que viu" não é retorno — é um wake à toa.
- **Status/FYI:** dobre no próximo handoff real ou **omita** (o dashboard já mostra o estado).
- **Sem carta:** corte saudação/assinatura/desculpa; não repita `reply_required` na prosa.

## 4. Endereçamento
`to-<destino>__from-<origem>__<id>.handoff`. O `bus-inbox` te entrega tudo `to-<você>__*` do seu projeto (novos + retornos); correlacione retornos por `BUS_IN_REPLY_TO`. Só endereça o mesmo projeto.

## Setup: gate de concorrência (hook + lock por projeto)
**Por quê:** o limite de requisições é da **conta** Claude. O gate serializa o trabalho por `/bus` num **lock POR PROJETO** (`<projeto>/.bus-lock`) — 1 especialista por vez **dentro** do projeto, mas **projetos diferentes rodam em paralelo** — e torna checagens de inbox vazia **de graça** (bloqueia o `/bus` antes da API).

Registre o hook **`UserPromptSubmit`** no `settings.json` global (`~/.claude/settings.json`), apontando pro `bus-gate`:
```json
{ "hooks": { "UserPromptSubmit": [ { "hooks": [ { "type": "command", "command": "<comando abaixo>" } ] } ] } }
```
- **Windows:** `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<raiz>\bin\bus-gate.ps1"`
- **macOS/Linux:** `bash "<raiz>/bin/bus-gate.sh"`

O hook é **fail-open** (erro → deixa passar): grava o `seen`, defere (`exit 2`, sem custo de API) se outro **do mesmo projeto** segura o lock ou se sua inbox está vazia, e adquire o lock quando há handoff. O passo 7 libera o lock; um **lease de 30 min** cobre quedas. Ele também intercepta **`/bus-message <texto>`** — o operador enfileira uma instrução pro especialista da sessão **sem acordar o modelo** (o hook escreve o handoff `operador→slug` e bloqueia o prompt, custo zero) — e a **pausa por projeto** (marcador `<projeto>/.bus-paused`, ligado/desligado pelo dashboard): enquanto pausado, o gate defere o processamento **sem interromper** quem já está no meio. (Detalhes em `REFERENCE.md`.)

**Prioridade / CONTROLADOR:** cada especialista tem uma **prioridade** (default `1000`; menor cede mais), setada pelo 3º arg do `/bus`. O gate faz **ceder a vez** (`exit 2`) quem tem trabalho **e** há handoff pra alguém de prioridade **maior**. O especialista de **menor prioridade** (ex.: `0`) é o **CONTROLADOR**: consolida por último, é dono do backlog de macro-tarefas (despacha a próxima onda quando os outros esvaziam — ninguém ocioso), e é o ponto de resumo pro operador. Sem controlador (ninguém < 1000): peer-to-peer, cada um consolida a própria frente. ⚠️ *Starvation:* num projeto sempre cheio, o low-prio pode esperar (é o comportamento pedido).

## Modelo de coordenação
- **Quem origina, coordena.** Acompanhe, cobre os retornos, integre, encerre.
- **Peer-to-peer** (dentro do projeto). Sem maestro central.
- **Não assuma frente alheia.** No máximo observe/valide e informe o operador. Conflitos sobem pro operador.
- **Output pro operador: o mínimo.** O operador não lê o chat de cada especialista — fale o **mínimo** (no máximo 1 linha, ou nada); não anuncie despacho nem narre a mecânica. Resumo detalhado é sob demanda (e, havendo controlador, é papel dele).

### ⚠️ Mantenha o fio vivo — NÃO encerre com trabalho pendente
O auto-recheck (cron) é a **campainha do seu inbox, não o despertador do seu plano**: ele só te acorda quando chega um **handoff no SEU inbox** — **nunca** pra continuar o seu próprio plano/memória. Se você encerrar com "continuo no próximo tick" e o trabalho está **na sua cabeça** (não no inbox), o **fio MORRE**: o gate defere todo tique de inbox vazio (`nada pendente — pulando`) e ninguém te acorda até o operador rodar `/bus` na mão. Isso **trava o bus**. Regras:
1. **Faça agora o que dá pra fazer agora.** Antes de encerrar: drene o inbox, **envie todos os handoffs** que já dá pra mandar, e execute **todos** os passos do seu plano que **não dependem de terceiros** — neste turno. **Não fatie o seu próprio trabalho em tiques.**
2. **Nunca "espere" um handoff que você não mandou.** Só encerre pra aguardar resposta se você **JÁ ENVIOU** o handoff (o *enviar* confirmou o `SENT=`). Aí o loop fecha sozinho: o cron do destino processa → responde → **o seu cron te acorda** com o retorno. Se o trabalho ainda está no plano, **mande o handoff ANTES de encerrar**.
3. **Precisa mesmo pausar uma tarefa longa SUA** (pra ceder o lock ou porque é gigante)? Não confie no cron pra lembrar do plano — **enfileire um self-handoff**: *enviar* com `-To <você> -From <você>` (`--to`/`--from`), **SEM** `-ReplyRequired`/`--reply`, descrevendo o próximo passo. O seu próprio cron te re-acorda pra continuar (o plano vira handoff no inbox, não fica só na sua cabeça).
4. **Não vigie os outros.** Se você mandou o handoff e o destino está online, o cron dele processa e o seu te acorda — não precisa checar lock nem ficar de vigia. Se o destino estiver **offline**, o handoff espera no inbox dele (o dashboard mostra) e quem religa é o **operador**: **avise o operador** em vez de encerrar em silêncio dependendo de alguém parado.

## Notas / limitações
- **Projeto = isolamento** e é **obrigatório** (sem `default`). Só vê/endereça o mesmo projeto.
- Sessões precisam estar **abertas** (o cron só dispara com o app aberto; reabriu → `/bus <slug> <projeto>`, ou `/bus-reload` só pra religar o cron).
- **Entrega automática:** o cron do destino (a cada 1 min) processa os handoffs sozinho — não precisa anunciar nem rodar `/bus` manual. Destino fechado → o handoff espera no inbox (visível no dashboard) até reabrir.
- Handoff sem token válido vai pra `rejected/`. **Crash no meio:** o arquivo fica em `processing/` pra reprocessamento.
