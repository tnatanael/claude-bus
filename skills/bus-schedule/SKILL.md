---
name: bus-schedule
description: Cria/lista/remove HANDOFFS AGENDADOS — tarefas do SO (Task Scheduler no Windows, cron no Unix) que injetam um handoff operador→especialista no inbox do BUS numa cadência (diária/semanal), SEM acordar modelo no disparo. É um "/bus-message com gatilho de tempo". Invoque /bus-schedule create <prompt>, /bus-schedule list, ou /bus-schedule remove <slug>.
---

# /bus-schedule — handoffs agendados (cria / lista / remove)

Agenda um handoff recorrente `operador→destino` no inbox do BUS. No disparo, uma tarefa do SO chama o `bus-send` direto — **SEM acordar modelo** (igual ao `/bus-message`, só que no relógio). Você (agente) só trabalha **agora**, no setup; a tarefa depois roda sozinha.

`$ROOT` = `${CLAUDE_PLUGIN_ROOT}`. **`PS`** = `powershell -NoProfile -ExecutionPolicy Bypass -File`. Toda a **mecânica** (`-From operador`, `-BusRoot` absoluto, corpo lido fresco, launcher oculto, isolar o bus-send num processo filho, log, principal Interactive/Limited, durabilidade) está **encapsulada** no `bus-schedule.ps1`/`.sh` — você só o chama.

| Op | Windows | macOS / Linux |
|---|---|---|
| **criar** | `PS "$ROOT\bin\bus-schedule.ps1" -Action create -Slug <s> -Project <p> -Dest <d> -Cadence daily\|weekly [-Days Mon,Wed,Fri] -Time HH:mm -BodyFile <arq>` | `bash "$ROOT/bin/bus-schedule.sh" create --slug <s> --project <p> --dest <d> --cadence daily\|weekly [--days mon,wed,fri] --time HH:mm --body-file <arq>` |
| **listar** | `PS "$ROOT\bin\bus-schedule.ps1" -Action list` | `bash "$ROOT/bin/bus-schedule.sh" list` |
| **remover** | `PS "$ROOT\bin\bus-schedule.ps1" -Action remove -Slug <s>` | `bash "$ROOT/bin/bus-schedule.sh" remove --slug <s>` |

## `/bus-schedule list` e `/bus-schedule remove <slug>`
Chame direto o *listar* / *remover* e reporte a saída. (Remover apaga a tarefa do SO **e** os artefatos em `~/.claude/bus-schedules/<slug>/`.)

## `/bus-schedule create <prompt>` — fluxo
1. **Identidade:** resolva via `bus-name` (sem args) → **PROJECT** + seu **SLUG**. `NONE` → esta sessão não está no BUS; peça pro operador rodar `/bus <slug> <projeto>` e **pare**.
2. **Parâmetros de cadência** (pergunte ao operador, curto, o que faltar):
   - **Dest** — pra quem vai o handoff (default = **você mesmo**, o slug desta sessão: um auto-kick recorrente).
   - **Cadência** — diária, ou semanal + dias.
   - **Horário** — `HH:mm` (24h).
   - **Slug da automação** — proponha um curto a partir do prompt (ex.: `daily-status`) e confirme.
3. **MELHORE o prompt** (o valor do skill): reescreva o `<prompt>` do operador aplicando as boas práticas de corpo —
   - **Âncora na DATA REAL:** o handoff manda o destino rodar `Get-Date`/`date` e ancorar tudo na data/hora reais do sistema — **nunca** na data do contexto dele (pode estar defasada; ela define o dia da semana).
   - **Autonomia + revisão DEPOIS:** o destino age com autonomia (decide sequenciamento/táticas, **não pausa** esperando o operador); o operador revisa depois.
   - **Tracking:** manter os arquivos de acompanhamento do projeto atualizados (é a base do "revisar depois").
   - Se o dest é o **controlador**: **orquestrar os especialistas, não fazer tudo sozinho**.
   Mostre o corpo final.
4. **CONFIRME** com o operador: `projeto → dest`, cadência @ horário, slug, e o corpo melhorado. Só siga com um **sim**.
5. **Escreva o corpo** num arquivo temp (ferramenta **Write**) e **crie** com o comando *criar* (passando esse `-BodyFile`/`--body-file`).
6. **Teste-dispare 1× e LIMPE** (não deixe um handoff fora de cadência pro dest processar):
   - Windows: `Start-ScheduledTask -TaskName "bus-schedule-<slug>" -TaskPath "\claude-bus\"`; espere ~7s; leia o `~/.claude/bus-schedules/<slug>/send.log` (espere `exit=0` + `ID=`).
   - Ache o handoff de teste no inbox (`<busRoot>/inbox/to-<dest>__from-operador__*.handoff`, o mais novo), confira corpo/acentos/`auth:`, e **APAGUE-O**.
   - (Unix: o disparo manual é `bash ~/.claude/bus-schedules/<slug>/_send.sh`.)
7. **Reporte** o próximo disparo (`Get-ScheduledTaskInfo`) e **onde fica o `body.txt`** — editar o corpo depois **NÃO** exige re-registrar (o `bus-send` lê o body fresco a cada disparo).

## Notas
- **Durável:** artefatos em `~/.claude/bus-schedules/<slug>/` (fora do `%TEMP%`/`/tmp`, que o SO limpa). `body.txt` editável a quente.
- **Não acorda modelo:** o disparo é puro `bus-send`. O dest processa no próximo `/bus`/tique dele; fechado → o handoff espera no inbox.
- **Windows:** tarefa `Interactive/Limited` do usuário atual (rejeita "run whether logged on or not"); se o Agendador travar, um **reboot** conserta. **Unix:** entrada de `crontab` marcada `# bus-schedule:<slug>`.
