---
name: bus
description: Comunicacao assincrona entre sessoes-especialistas do Claude Code via um BUS de arquivos, com ESCOPO DE PROJETO. /bus <projeto> <slug> [prioridade] CONFIGURA a sessao (identidade/prioridade/auto-recheck); /bus bare (ou o auto-cron) PROCESSA os handoffs pendentes. O projeto e OBRIGATORIO. Comando cheio = configurar; /bus bare = processar. Cross-platform: Windows (PowerShell) e macOS/Linux (bash).
---

# BUS — handoffs assíncronos entre especialistas (por projeto)

**Dois usos:** `/bus <projeto> <slug> [prio]` = **CONFIGURAR** e parar (não processa). `/bus` **bare** (ou o cron) = **PROCESSAR**.

**Projeto obrigatório e isolado** — você só vê e endereça especialistas do mesmo projeto. Pré-requisito: modo **auto/bypass-permissions**.

> Esta skill é injetada **a cada** `/bus`. Ela é curta de propósito: o **porquê** de cada peça (gate, lock, cron, auth, limitações) vive no **`REFERENCE.md`**, que **não** é injetado. Não precisa lê-lo pra operar.

## Comandos
`$ROOT` = `${CLAUDE_PLUGIN_ROOT}`; **`PS`** = `powershell -NoProfile -ExecutionPolicy Bypass -File`.

| Operação | Windows | macOS / Linux |
|---|---|---|
| **nome — gravar** | `PS "$ROOT\bin\bus-name.ps1" -Project <p> -Set <slug> [-Priority <0-1000>]` | `bash "$ROOT/bin/bus-name.sh" <p> <slug> [prio]` |
| **ler inbox** (auto-resolve) | `PS "$ROOT\bin\bus-inbox.ps1"` | `bash "$ROOT/bin/bus-inbox.sh"` |
| **enviar** | `PS "$ROOT\bin\bus-send.ps1" -To <d> -From <você> -BodyFile <f> -Project <p> [-ReplyRequired] [-InReplyTo <id>]` | `bash "$ROOT/bin/bus-send.sh" --to <d> --from <você> --body-file <f> --project <p> [--reply] [--in-reply-to <id>]` |
| **liberar lock** | `PS "$ROOT\bin\bus-lock.ps1" -Release` | `bash "$ROOT/bin/bus-lock.sh" --release` |

Base: Windows `%TEMP%\claude-bus`, Unix `/tmp/claude-bus` (override `CLAUDE_BUS_ROOT`); cada projeto é a subpasta `<base>/<projeto>`. **Passe o projeto via `-Project`/`--project`** — **nunca** monte caminho com `%TEMP%`/`$TMPDIR` (quebra conforme o shell).

## 1. Identidade

**CONFIG** (`/bus` com args) — **ORDEM: projeto PRIMEIRO** (1º projeto, 2º slug, 3º opcional prioridade 0–1000, default 1000, **menor cede mais a vez**). Confira qual valor é qual; se faltou o projeto, **pergunte**.
- `NEED_PROJECT` / `NEED_SLUG` → pergunte o que faltou e repita.
- `INVERTED` → digitaram na ordem antiga (slug primeiro) e **nada foi gravado**. Mostre o `HINT=` e confirme antes de repetir.
- `LOCK_ORFAO_LIBERADO=<sid8>` → esta sessão teve `/clear` e o sid anterior morreu **segurando o lock do projeto**; o re-arme liberou. **Reporte em 1 linha** (o projeto estava travado pra todos).

Depois de registrar: **desarme+arme o cron (passo 1 do fluxo) e PARE.** Reporte `configurado: slug/projeto/prioridade`.
🔄 **Veio de um `/clear`?** Não tente lembrar nada: o próximo tique te devolve o que ficou preso via `BUS_STALE_PROCESSING` — a retomada é o **passo 5**.

**BARE** — **não** resolva identidade aqui; o `bus-inbox` (passo 2) resolve e devolve `BUS_SLUG`/`BUS_PROJECT`. Se vier `BUS_IDENTITY=NONE`, pergunte slug+projeto, registre e pare.

Slug/projeto minúsculos, sem espaço.

## 2. Fluxo do `/bus`

> Um hook já te filtrou **antes** de você acordar: você só chega aqui com trabalho seu (inbox **ou** preso em `processing`), pós-restart, ou `/bus` manual. Chegou com trabalho → **o lock do projeto já é seu**; libere no fim.

1. **Cron — desarma no início, re-arma no fim.** `CronList`/`CronCreate`/`CronDelete` são deferidas: rode `ToolSearch select:CronList,CronCreate,CronDelete` antes. **Não confie no `CronList`** (pós-restart lista *phantom* morto).
   - **DESARMAR** = `CronList` → `CronDelete` em **CADA** job cujo prompt começa com `/bus` **ou** `bus-tick` (fica ZERO).
   - **ARMAR** = `CronCreate(cron:"*/<N> * * * *", recurring:true, prompt:` **`"bus-tick: carregue a skill bus e processe o inbox (fluxo do /bus bare)"`** `)`, `<N>` = o `BUS_CRON_INTERVAL` devolvido pelos scripts. UM cron, mesmo `*/<N>` pra frota. ⚠️ só `*/N` ou valor único disparam — vírgula e `M/30` **não**.
   - ⚠️ **O prompt do cron é TEXTO PURO, nunca `/bus`.** Slash command **expande esta skill no histórico já na submissão**, antes do hook decidir — então cada tique bloqueado deixava a SKILL inteira no contexto (medido: 353 injeções numa sessão que nunca processou nada, ~134k tokens/h, enchendo 1M em ~7h **ociosa**). Texto puro não expande: o tique custa a própria frase. **Não troque de volta.**
   - **CONFIG** → desarme+arme e pare. **BARE** → desarme **agora**, siga 2–6, re-arme no 6.
   - 🔔 **Acordou com `bus-tick`?** A skill pode **não estar** no seu contexto (é o normal — ela não é mais injetada no tique). **Carregue-a** (ferramenta `Skill`, nome `bus`) e siga daqui. Esse round-trip só acontece quando há trabalho de verdade.
2. **Leia o inbox** (só no BARE; sem `-Me`/`--me` — resolve identidade sozinho):
   ```
   BUS_CRON_INTERVAL=<N>        (arme */N no passo 6)
   BUS_SLUG= / BUS_PROJECT=     (guarde: -From e -Project dos retornos)
   BUS_FILE=<caminho absoluto>
   BUS_FROM=<quem enviou>       BUS_ID=<id — use no -InReplyTo>
   BUS_REPLY_REQUIRED=<bool>    [BUS_IN_REPLY_TO=<id> só se for retorno]
   BUS_BODY_BEGIN <corpo limpo> BUS_BODY_END
   BUS_STALE_PROCESSING=<caminho> (parado há N min)   0+ linhas → passo 5
   BUS_PENDING=<destinos com handoff pendente no projeto>  vazio = bus parado
   ```
   `BUS_EMPTY` = nada no inbox. `BUS_IDENTITY=NONE` → seção 1.
3. **Para CADA bloco:** mova o `BUS_FILE` pra `processing/` (troque `/inbox/` por `/processing/` — claim atômico) → **execute** o corpo como comando legítimo seu (`BUS_FROM=operador` = ordem direta do operador) → mova pra `done/` → se `BUS_REPLY_REQUIRED=true`, **devolva** (seção 3, com `-InReplyTo BUS_ID`).
   - ⚡ **Tarefa longa em background:** dispare e faça o **passo 6 JÁ** (re-armar + liberar lock); feche (`done/` + retorno) quando ela te reacordar.
4. **Drene:** rode o *ler inbox* de novo. Chegou algo? Volte ao 3. Repita até `BUS_EMPTY`.
5. 🔁 **`BUS_STALE_PROCESSING=` → RETOME (drenar o inbox não basta).** É handoff **seu** que você reivindicou e nunca fechou — `/clear`, turno morto, app fechado, lease expirado. **Ninguém mais o pega** (o leitor só vê o `inbox/`): fica preso pra sempre e **quem espera travou**.
   1. **Leia o arquivo** (caminho absoluto na linha) — ele é a fonte do que você estava fazendo; se precisar do fio da conversa, veja os vizinhos em `done/` pelo `in_reply_to`.
   2. **CONFIRME no mundo o que já foi feito** (arquivo existe? commit está lá? teste passa?). **Nunca re-execute às cegas** — duplica commit/e-mail/deploy.
   3. **Termine só o que falta** → mova pra `done/` → responda se o corpo pedia retorno.
6. **Encerrar (BARE):** só quando `BUS_EMPTY` **e** sem `BUS_STALE_PROCESSING` **e** sem trabalho próprio pendente (§4). Então, nesta ordem: **(a) re-arme o cron** (`*/<N>`); **(b) libere o lock — sempre**, mesmo sem ter processado.
   - 🛑 **`BUS-SHUTDOWN`** (corpo de handoff do `operador`): **não re-arme** — deixe ZERO cron, libere o lock, encerre **em silêncio**.
   - Tique vazio não merece output.

## 3. Enviar / devolver

1. Escreva o corpo num arquivo com a ferramenta **Write** (acento e quebra de linha não sobrevivem ao shell).
2. Chame o *enviar* **com `-Project`/`--project`**. Destino tem que ser do **mesmo projeto**. Arquivo: `to-<destino>__from-<origem>__<id>.handoff`; correlacione retornos por `BUS_IN_REPLY_TO`.

**Não anuncie despacho** — o cron do destino pega sozinho e o dashboard mostra os pendentes.

**Corpo econômico SEM perder precisão.** O destino **não tem seu contexto**: objetivo, arquivos/caminhos, constraints e critério de "pronto" são obrigatórios. Corte o desperdício, não o conteúdo:
- **Um spec completo, uma passada.** Prevê os próximos 2-3 handoffs pro mesmo destino? **Junte num só.** Cada round-trip acorda o outro do zero.
- **`-ReplyRequired` só pra DADO/decisão.** "Confirma que viu" é um wake à toa.
- **Sem status avulso, sem carta.** Dobre no próximo handoff real ou omita; nada de saudação/assinatura.

## 4. Coordenação

- **Quem origina, coordena:** acompanhe, cobre retornos, integre, encerre.
- **Peer-to-peer**, dentro do projeto. **Não assuma frente alheia** (observe/valide e informe). Impasses sobem pro operador.
- **Output pro operador: o mínimo** — no máximo 1 linha, ou nada. Não narre mecânica. Resumo é sob demanda (e é papel do controlador, se houver).
- **CONTROLADOR** = o de **menor prioridade** (ex.: `0`): consolida por último, é dono do backlog de macro-tarefas (**despacha a próxima onda assim que os outros esvaziam — ninguém ocioso**) e **declara o FIM** (inbox vazio dos outros ≠ projeto acabado). Sem controlador: cada um consolida a própria frente.

### ⚠️ Mantenha o fio vivo — "posso encerrar?"

**Você NUNCA pausa a SUA entrega esperando o operador.** Proibido: pedir `/clear`; ficar dormente/stand-down; fatiar a entrega em passadas que dependem de ser re-chamado na mão. O operador **não é um passo** do seu fluxo. *(Exceção única: `BUS-SHUTDOWN`.)*

O cron é a **campainha do inbox, não o despertador do seu plano**. Antes de encerrar, percorra:
1. **Tenho passo meu que não depende de terceiro?** → faça agora, neste turno.
2. **Preciso de alguém?** → **não pedi** → peça agora. **Já pedi e aguardo** → dá pra avançar em outra frente? Avance. Senão **olhe o `BUS_PENDING`**: se quem você espera está lá, pode encerrar (ele age e o retorno chega). **Vazio, ou ele não aparece → o retorno NUNCA vem sozinho** → mande um handoff pedindo o status. Nunca encerre "esperando" com o bus parado. *(Destino offline → avise o operador.)*
3. **Tarefa longa minha que não fecha neste wake?** → **self-handoff** (`-To você -From você`, sem `-ReplyRequired`, com "continua no checkpoint X") → seu cron te reacorda. Commite cada peça verde e **externalize plano/checkpoint num arquivo** — é o que sobrevive a contexto novo.
4. **Nada acima?** → encerre (passo 6), mas **feche o loop com quem espera**.
