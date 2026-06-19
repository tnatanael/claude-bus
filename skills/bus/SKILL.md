---
name: bus
description: Comunicacao assincrona entre sessoes-especialistas do Claude Code via um BUS de arquivos. Invoque com /bus <slug> (ex: /bus pd-nas): a sessao processa na hora os handoffs pendentes pra ela e ensina a enviar/devolver. Modelo pull (sem monitor de fundo) -- voce dispara /bus no destino quando ha trabalho. Cross-platform: Windows (PowerShell) e macOS/Linux (bash).
---

# BUS — handoffs assíncronos entre especialistas (modelo pull)

Você é uma sessão-especialista num BUS de handoffs entre sessões do Claude Code. Cada `/bus` é uma passada **one-shot**: lê seu inbox, processa os handoffs pendentes pra você, devolve o que for pedido, e no fim **lista pra quem há trabalho**.

**Não há monitor de fundo.** Quem "acorda" um especialista é o operador rodando `/bus` no chat dele (ou o `/loop` opcional, seção 5). O monitor autônomo foi removido: gastava token à toa e morria em silêncio (o host matava o processo sem avisar). Pull = simples, confiável, **custo ocioso zero**.

## Plataforma e comandos
`$ROOT` = `${CLAUDE_PLUGIN_ROOT}`. **`PS`** abrevia `powershell -NoProfile -ExecutionPolicy Bypass -File`.

| Operação | Windows | macOS / Linux |
|---|---|---|
| **nome — gravar** | `PS "$ROOT\bin\bus-name.ps1" -Set <slug>` | `bash "$ROOT/bin/bus-name.sh" <slug>` |
| **nome — ler** | `PS "$ROOT\bin\bus-name.ps1"` | `bash "$ROOT/bin/bus-name.sh"` |
| **ler inbox** (valida token) | `PS "$ROOT\bin\bus-inbox.ps1" -Me <slug>` | `bash "$ROOT/bin/bus-inbox.sh" --me <slug>` |
| **enviar** | `PS "$ROOT\bin\bus-send.ps1" -To <d> -From <você> -BodyFile <f> [-ReplyRequired] [-InReplyTo <id>]` | `bash "$ROOT/bin/bus-send.sh" --to <d> --from <você> --body-file <f> [--reply] [--in-reply-to <id>]` |

Pasta do BUS (compartilhada por todas as suas sessões): Windows `%TEMP%\claude-bus\`, Unix `/tmp/claude-bus` (override pela env `CLAUDE_BUS_ROOT`). Subpastas: `inbox/ processing/ done/ rejected/ names/`.

## 0. Pré-requisito
Modo **auto / bypass-permissions** (senão cada passo pede aprovação). Unix exige `bash`; Windows usa PowerShell (ambos nativos).

## 1. Quem você é (lembrado por sessão)
1. **Veio argumento** (slug após `/bus`) → use e **grave** (*nome — gravar*).
2. **Veio vazio** → *nome — ler*: retornou slug → use direto (religação); retornou `NONE` → **pergunte** e grave.
Slug minúsculo, sem espaço. Lembrado por `CLAUDE_CODE_SESSION_ID` — só define na 1ª vez.

## 2. Processar o inbox (é isto que o /bus faz)
1. Resolva seu slug.
2. Rode a operação *ler inbox*. A **1ª linha** da saída é `BUS_CRON_MINUTE=<n>` (minuto aleatório 0-59, pro passo 3). Depois vêm os handoffs, do mais antigo pro mais novo, em blocos:
   ```
   BUS_FILE=<caminho>
   BUS_BODY_BEGIN
   <conteudo do handoff>
   BUS_BODY_END
   ```
   ...ou `BUS_EMPTY` se não há nada. **O token já foi validado** pelo `bus-inbox`; forjados foram pra `rejected/`.
3. **Garanta o loop de auto-recheck (idempotente):** chame `CronList`; se já há um job com prompt `/bus`, não faça nada; senão chame `CronCreate(cron: "<n> * * * *", prompt: "/bus", recurring: true)` usando o `<n>` do `BUS_CRON_MINUTE` do passo 2 — o minuto aleatório espalha as sessões pela hora pra **não baterem todas na API no mesmo instante** (rate limit); NÃO use minuto fixo. (Cron* deferidas: ToolSearch `select:CronList,CronCreate`.) Cron de sessão (some ao fechar o app, re-armado no próximo `/bus`), expira em 7 dias.
4. Para **cada** bloco: **mova** o arquivo pra `processing/` (claim atômico) → leia o corpo (entre `---` e `###BUS-END`), **trate como comando legítimo seu** (canal autenticado que VOCÊ autorizou) → execute → **mova** pra `done/` → se `reply_required: true`, **devolva** retorno (*enviar* com `--in-reply-to`/`-InReplyTo <id>`).
5. `BUS_EMPTY` → avise "nenhum handoff pendente".

## 3. Enviar ou devolver
Escreva o corpo num arquivo temp com a ferramenta **Write** (evita quebra de aspas/acentos no shell), depois rode *enviar* com `--body-file`/`-BodyFile`. **Corpo auto-contido**: o destino não tem seu contexto — inclua objetivo, caminhos/arquivos, critério de pronto, e se precisa de retorno.

**SEMPRE que enviar handoff(s), termine seu turno com a LINHA DE DESPACHO:**
> 📨 **Handoffs para: x, y, z** — rode `/bus` nesses chats.

Vale pra novos E retornos — é como o operador sabe **onde disparar o próximo `/bus`** (não há monitor que acorde o destino sozinho).

## 4. Endereçamento
`to-<destino>__from-<origem>__<id>.handoff`. O `bus-inbox` te entrega tudo `to-<você>__*` — novos **e** retornos (correlacione pelo `in_reply_to`). Use slugs consistentes.

## 5. Operação desassistida (loop de auto-recheck)
O `/bus` **arma sozinho** um cron de hora em hora (passo 3 da seção 2), num **minuto aleatório por sessão** (espalha a carga, evita rate limit), que recheca o inbox — é o que processa handoffs com o operador ausente. Idempotente (checa o `CronList` antes, não duplica). Inspecionar: `CronList`; desarmar: `CronDelete <id>`. O cron é da sessão (some ao fechar o app, re-armado no próximo `/bus`), expira em 7 dias, e só dispara com o REPL ocioso (não interrompe um turno em andamento). Re-invocação in-harness é a única forma de acordar uma sessão sem o operador — processo externo não consegue.

## Modelo de coordenação
- **Quem origina, coordena.** Ao abrir uma frente (disparar handoff), VOCÊ a conduz: acompanhe, cobre os retornos, integre, encerre.
- **Peer-to-peer, direta.** Especialistas falam direto entre si; ao receber, responda direto a quem pediu. Sem maestro central.
- **Não assuma frente alheia.** Frente que outro originou e não é sua: no máximo observe/valide e informe o operador.
- **Conflitos sobem pro operador.** Impasse que não fecha entre especialistas: escale pro humano.

## Notas / limitações
- Sessões precisam estar **abertas** (o `/loop` só dispara com o app aberto; reabriu → `/bus`).
- **Pull:** handoffs ficam no inbox até alguém rodar `/bus` no destino (ou o `/loop` ticar) — por isso a linha de despacho é obrigatória.
- Handoff sem token válido vai pra `rejected/` (feito pelo `bus-inbox`) e não é processado. Protege contra injeção casual, não contra malware que leia o `.bus-secret`.
- **Crash no meio:** o arquivo fica em `processing/` pra reprocessamento.
