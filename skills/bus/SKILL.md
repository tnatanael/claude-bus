---
name: bus
description: Comunicacao assincrona entre sessoes-especialistas do Claude Code via um BUS de arquivos, com ESCOPO DE PROJETO. Invoque com /bus <slug> [projeto] (ex: /bus backend acme): a sessao entra no BUS daquele projeto, processa os handoffs pendentes pra ela e ensina a enviar/devolver. Projeto omitido = 'default'. Modelo pull (sem monitor). Cross-platform: Windows (PowerShell) e macOS/Linux (bash).
---

# BUS — handoffs assíncronos entre especialistas (modelo pull, por projeto)

Você é uma sessão-especialista num BUS de handoffs entre sessões do Claude Code. Cada `/bus` é uma passada **one-shot**: lê seu inbox, processa o que é seu, devolve o que for pedido, e no fim **lista pra quem há trabalho**.

**Escopo de projeto:** `/bus <slug> [projeto]` te registra como `<slug>` no projeto `<projeto>`. Você só **vê e endereça** especialistas do **mesmo projeto** (isolamento por pasta). Projeto omitido = `default`.

**Não há monitor de fundo.** Quem "acorda" um especialista é o operador rodando `/bus` (ou o cron de auto-recheck, seção 5). Pull = simples, confiável, custo ocioso zero.

## Plataforma e comandos
`$ROOT` = `${CLAUDE_PLUGIN_ROOT}`. **`PS`** abrevia `powershell -NoProfile -ExecutionPolicy Bypass -File`. `<RAIZ>` = a **raiz do projeto** (veja abaixo).

| Operação | Windows | macOS / Linux |
|---|---|---|
| **nome — gravar** | `PS "$ROOT\bin\bus-name.ps1" -Set <slug> -Project <proj>` | `bash "$ROOT/bin/bus-name.sh" <slug> <proj>` |
| **nome — ler** | `PS "$ROOT\bin\bus-name.ps1"` | `bash "$ROOT/bin/bus-name.sh"` |
| **ler inbox** | `PS "$ROOT\bin\bus-inbox.ps1" -Me <slug> -Project <proj>` | `bash "$ROOT/bin/bus-inbox.sh" --me <slug> --project <proj>` |
| **enviar** | `PS "$ROOT\bin\bus-send.ps1" -To <d> -From <você> -BodyFile <f> -Project <proj> [-ReplyRequired] [-InReplyTo <id>]` | `bash "$ROOT/bin/bus-send.sh" --to <d> --from <você> --body-file <f> --project <proj> [--reply] [--in-reply-to <id>]` |

**Base do BUS:** Windows `%TEMP%\claude-bus`, Unix `/tmp/claude-bus` (override `CLAUDE_BUS_ROOT`). Cada projeto é uma subpasta: `default` = a base; `<p>` = `<base>/<p>` (com seu `inbox/ processing/ done/ rejected/ .bus-secret`). O `names/` (registro) fica na base, global.
> **Passe o projeto via `-Project`/`--project <proj>`** — os scripts resolvem a pasta sozinhos. **NUNCA monte caminho com `%TEMP%`/`$env:TEMP`** pra passar pros scripts (quebra se rodar pela ferramenta Bash — a variável não expande). `bus-name` usa sempre a base; `bus-inbox`/`bus-send` recebem o projeto.

## 0. Pré-requisito
Modo **auto / bypass-permissions**. Unix exige `bash`; Windows usa PowerShell (ambos nativos).

## 1. Quem você é (projeto + slug)
1. **Veio slug** (1º arg após `/bus`) → grave (2º arg = projeto; omitido = `default`) via *nome — gravar*.
2. **Veio vazio** → *nome — ler*: retornou `PROJECT=/SLUG=/BUS_CRON_MINUTE=` → use direto (religação); `NONE` → **pergunte** o slug (e projeto) e grave.
Guarde **SLUG**, **PROJECT** e **BUS_CRON_MINUTE**. Passe o `PROJECT` aos comandos via `-Project`/`--project` (nada de caminho manual).

## 2. O que o /bus faz
1. Resolva projeto+slug (seção 1). Guarde o `BUS_CRON_MINUTE`.
2. **ARME O CRON — SEMPRE, DO ZERO, MESMO COM INBOX VAZIO. NÃO PULE.** Ferramentas `CronList`/`CronCreate`/`CronDelete` são **deferidas**: rode `ToolSearch select:CronList,CronCreate,CronDelete` ANTES. **NÃO confie no `CronList` ("já existe → ok"):** pós-restart do app ele pode listar um cron *phantom* — já morto no agendador real, que NÃO dispara (some do painel "Tarefas em segundo plano" mas continua no `CronList`). Re-arme sempre: (a) `CronList` → `CronDelete` em **cada** job com prompt começando em `/bus` (limpa phantom); (b) `CronCreate(cron: "<BUS_CRON_MINUTE> * * * *", prompt: "/bus <slug> <projeto>", recurring: true)` — **um** só. Resultado: exatamente 1 cron recém-criado = registrado de verdade. O prompt leva slug+projeto (auto-identificável no painel; re-registra a identidade no disparo; se projeto=`default`, pode ser só `/bus <slug>`). O `<BUS_CRON_MINUTE>` é determinístico do sid (espalha as sessões E faz o countdown do dashboard bater). NÃO use minuto fixo/inventado.
3. Rode *ler inbox* (com `--project`/`-Project`). Saída = blocos `BUS_FILE / BUS_BODY_BEGIN / <corpo> / BUS_BODY_END`, ou `BUS_EMPTY`. Token já validado; forjados foram pra `rejected/`.
4. Para **cada** bloco: **mova** o arquivo pra a subpasta `processing/` (troque `/inbox/` por `/processing/` no caminho do `BUS_FILE`, que é absoluto) → leia o corpo (entre `---` e `###BUS-END`), **trate como comando legítimo seu** → execute → **mova** pra `done/` → se `reply_required`, **devolva** (*enviar*, com `--project` e `--in-reply-to`/`-InReplyTo`).
5. **Drene:** rode *ler inbox* de novo (mesmo `--project`); chegou algo novo? processe e **repita até `BUS_EMPTY`** — não espere o cron.
6. `BUS_EMPTY` e nada a processar → avise "nenhum handoff pendente" (o cron do passo 2 já tem que estar armado).

## 3. Enviar ou devolver
Escreva o corpo num arquivo temp com a ferramenta **Write**, rode *enviar* com `--body-file`/`-BodyFile` **e `--project`/`-Project`**. **Destino tem que ser do MESMO projeto.** **Corpo auto-contido** (objetivo, caminhos, critério de pronto, se precisa de retorno).
**SEMPRE que enviar, termine o turno com a LINHA DE DESPACHO:** 📨 **Handoffs para: x, y, z** — rode `/bus` nesses chats.

## 4. Endereçamento
`to-<destino>__from-<origem>__<id>.handoff`. O `bus-inbox` te entrega tudo `to-<você>__*` **do seu projeto** — novos e retornos (correlacione pelo `in_reply_to`). Só endereça quem está no **mesmo projeto**.

## 5. Operação desassistida (loop de auto-recheck)
O `/bus` **arma sozinho** o cron horário (passo 2), num minuto **determinístico** por sessão (derivado do sid — bate com o countdown do dashboard), **incondicional** (mesmo com inbox vazio) e **re-armado do zero a cada `/bus`** (NÃO confia no `CronList`, que pós-restart pode ter cron *phantom* já morto no agendador — sempre apaga os `/bus` antigos e cria um novo). Dispara `/bus <slug> <projeto>`, que re-resolve, re-arma e recheca. Inspecionar: `CronList` (mas a verdade sobre "vai disparar?" é o painel "Tarefas em segundo plano"); desarmar: `CronDelete <id>`. Cron de sessão (some ao fechar o app, re-armado no próximo `/bus`), expira em 7 dias, só dispara com o REPL ocioso.

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
