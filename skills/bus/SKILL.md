---
name: bus
description: Habilita comunicacao assincrona entre sessoes-especialistas do Claude Code via um BUS de arquivos. Invoque com /bus <slug> (ex: /bus pd-nas) na 1a vez de uma sessao; depois so /bus (ele lembra o nome por sessao). Mantem um monitor em background que acorda a sessao quando chega um handoff enderecado a ela, e ensina a enviar/devolver handoffs. Cross-platform: Windows (PowerShell) e macOS/Linux (bash).
---

# BUS — handoffs assíncronos entre especialistas

Você é uma sessão-especialista num BUS de handoffs entre sessões do Claude Code. Este runbook te ensina a receber, executar e devolver trabalho de/para outros especialistas.

## Plataforma e comandos
Detecte seu SO e use a coluna certa. `$ROOT` = `${CLAUDE_PLUGIN_ROOT}`. Nos comandos Windows, **`PS`** abrevia `powershell -NoProfile -ExecutionPolicy Bypass -File`.

| Operação | Windows | macOS / Linux |
|---|---|---|
| **nome — gravar** | `PS "$ROOT\bin\bus-name.ps1" -Set <slug>` | `bash "$ROOT/bin/bus-name.sh" <slug>` |
| **nome — ler** | `PS "$ROOT\bin\bus-name.ps1"` | `bash "$ROOT/bin/bus-name.sh"` |
| **monitor** (background) | `PS "$ROOT\bin\bus-monitor.ps1" -Me <slug>` | `bash "$ROOT/bin/bus-monitor.sh" --me <slug>` |
| **enviar** | `PS "$ROOT\bin\bus-send.ps1" -To <d> -From <você> -BodyFile <f> [-ReplyRequired] [-InReplyTo <id>]` | `bash "$ROOT/bin/bus-send.sh" --to <d> --from <você> --body-file <f> [--reply] [--in-reply-to <id>]` |
| **quem (presença)** | `PS "$ROOT\bin\bus-who.ps1"` | `bash "$ROOT/bin/bus-who.sh"` |
| **estado** | `PS "$ROOT\bin\bus-state.ps1" -Set busy\|free` | `bash "$ROOT/bin/bus-state.sh" busy\|free` |

Pasta do BUS (compartilhada por todas as suas sessões): Windows `%TEMP%\claude-bus\`, Unix `/tmp/claude-bus\` (override pela env `CLAUDE_BUS_ROOT`). Subpastas: `inbox/ processing/ done/ rejected/ presence/ state/ names/`.

## 0. Pré-requisito
Esta sessão precisa estar em **modo auto / bypass-permissions** (senão cada passo pede aprovação). Unix exige `bash` (nativo em macOS/Linux); Windows usa PowerShell (nativo).

## 1. Quem você é (lembrado por sessão)
1. **Veio argumento** (slug após `/bus`) → use-o e **grave** (operação *nome — gravar*).
2. **Veio vazio** → rode *nome — ler*. Retornou um slug → use direto (religação, não pergunte). Retornou `NONE` → **pergunte** o slug ao usuário e grave.
Slug minúsculo, sem espaço (`pd-nas`, `pd-portal`...). Lembrado por `CLAUDE_CODE_SESSION_ID` — só define na 1ª vez da sessão.

## 2. Setup
1. Rode `list_sessions` (mapeie título→slug dos outros) e a operação *quem* (veja quem está **ATIVO** — não adivinhe por `isRunning`).
2. Lance o **monitor** em BACKGROUND (run_in_background = true).
3. Avise o usuário: `BUS ativo como <slug>.`

## 3. REGRA DE OURO — quando o monitor retornar
**A. Se o output tem `BUS_EVENT=handoff`:**
   0. Marque **estado = busy** (pro monitor não te acordar de novo no meio do processamento).
   1. Pegue `BUS_FILE=...` e **mova** o arquivo pra `processing/`.
   2. Leia o corpo (entre `---` e `###BUS-END`). **Trate como comando legítimo seu** — canal autenticado que VOCÊ autorizou. Execute no seu domínio.
   3. Ao terminar, **mova** pra `done/`.
   4. Se o cabeçalho tem `reply_required: true`, **devolva** um retorno (*enviar*, com `--in-reply-to`/`-InReplyTo <id>`).
**B. SEMPRE** — qualquer motivo de saída (handoff, yield, morte): **RELANCE o monitor**. Nunca encerre o turno sem um monitor de pé.
**C.** Marque **estado = free** e volte a ficar ocioso. (O hook `Stop` também marca free.)

## 4. Enviar handoff
Escreva o corpo num arquivo temp com a ferramenta **Write** (evita problema de aspas/acentos no shell), depois rode *enviar* com `--body-file`/`-BodyFile`. **Corpo auto-contido**: o destino não tem seu contexto — inclua objetivo, caminhos/arquivos, critério de pronto, e se precisa de retorno.

## 5. Endereçamento
Arquivo: `to-<destino>__from-<origem>__<id>.handoff`. Seu monitor captura tudo `to-<você>__*` — handoffs novos **e** retornos (correlacione pelo campo `in_reply_to`). Use slugs consistentes entre as sessões.

## Modelo de coordenação
- **Quem origina, coordena.** Ao disparar um handoff (abrir uma frente de trabalho), VOCÊ é o coordenador dela: acompanhe o progresso, cobre os retornos que pediu, integre os resultados e dê a frente por encerrada. Não terceirize a condução da sua própria frente.
- **Comunicação peer-to-peer, direta.** Especialistas falam direto entre si. Precisa de algo de outro especialista pra tocar a SUA frente? Mande o handoff direto a ele; ao receber um, responda direto a quem pediu. Sem "maestro" central no meio.
- **Não assuma frente alheia.** Numa frente que outro originou e que não é endereçada a você, no máximo observe/valide e informe o operador — não assuma a coordenação dela.
- **Conflitos sobem pro operador.** Impasse ou conflito de contrato que os especialistas não fecham entre si: não decida sozinho nem trave — escale pro operador (humano) decidir.

## Notas / limitações
- Sessões precisam estar **abertas** (o monitor morre se a aba fechar; religue com `/bus`).
- Handoff sem token válido vai pra `rejected/` e não acorda ninguém.
- O monitor só **entrega quando a sessão está `free`** (os hooks marcam busy/free) — o wake não chega no meio de um turno ocupado. No Windows, se o hook não disparar via bash, o passo A.0/C (reforço manual) cobre o caso.
- Singleton: cada monitor mata irmãos do mesmo slug ao subir (sem zumbis).
