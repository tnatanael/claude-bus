---
name: bus-reload
description: DESTRAVA esta sessao e re-arma o cron de auto-recheck do BUS dela — NAO processa o inbox. Varre as cinco causas de o tique nao chegar (tarefa pendurada, identidade orfa apos /clear, lock orfao no proprio nome, projeto pausado, cron phantom) e re-arma do zero. Invoque com /bus-reload. Use apos reabrir o app / restart, ou quando o dashboard mostrar o especialista sumido do BUS. Le a identidade ja registrada; nao precisa de argumentos.
---

# /bus-reload — re-armar o cron do BUS (sem processar)

**Destrava esta sessão e re-arma o cron de auto-recheck** dela. Até a v0.9.22 ele destravava só o cron (apagar phantom + re-armar do zero); o passo 0 estendeu isso pras outras quatro causas de sumiço. **NÃO** lê nem processa o inbox. Útil após reabrir o app: o cron é de sessão (em memória) e morre no restart — este comando o traz de volta rápido, sem disparar processamento.

`$ROOT` = `${CLAUDE_PLUGIN_ROOT}`. **`PS`** = `powershell -NoProfile -ExecutionPolicy Bypass -File`.

## Passos

### 0. DESTRAVE primeiro — re-armar cron não adianta se a sessão está bloqueada por outra coisa

Este comando costuma chegar porque **alguém notou que você sumiu do BUS** (o dashboard mostra o `seen` congelado, ou um par te cutucou por `SendMessage`). Antes de re-armar, varra as cinco coisas que impedem o tique de chegar ou de virar trabalho. Todas são verificáveis por você, sozinho, em segundos:

1. ⏱️ **Tarefa pendurada — a mais comum.** O tique só entra em sessão **ociosa**: enquanto um comando roda em foreground, ou uma tarefa de fundo continua viva, o cron **não dispara** e você some do BUS sem erro nenhum. Olhe suas tarefas em segundo plano e **encerre o que não for essencial** (`TaskStop`). Daqui pra frente: **timeout explícito** em tudo que sai da máquina (`ssh`, `gh`, `curl`, suíte, deploy); nada de laço `for`+`sleep` nem espera sem prazo.
2. 🪪 **Identidade órfã.** O passo 1 devolveu `NONE`? Seu **sid mudou** (`/clear`, restart) e `names/` ainda aponta pra encarnação anterior — você não tem cron e **nunca mais vai gatear**. `/bus-reload` **não resolve isso**: rode **`/bus <projeto> <slug>`**, que re-registra o sid vivo, evicta o antigo e re-arma. ⚠️ O teste é **este passo devolver `NONE`** — não o estado do `seen/`, que é escrito também por `bus-inbox` e `bus-name` e portanto não mede o tique.
3. 🔒 **Lock órfão em seu próprio nome.** Uma encarnação anterior sua pode ter morrido segurando o slot — o projeto inteiro defere até o lease vencer. Libere (`bus-lock -Release`); um lock em nome do **seu** slug só pode ser seu.
4. ⏸️ **Projeto pausado** (`<projroot>/.bus-paused`): o tique chega e defere, por desenho. Você não tira isso — só o dashboard. **Reporte ao operador** e pare.
5. 🧟 **Cron phantom**: pós-restart o `CronList` pode listar um cron morto que **não dispara**. É o que o passo 2 resolve re-armando **do zero** — nunca reaproveite job existente.

Achou algo nos itens 2 ou 4? **Pare e faça o que a linha manda** — re-armar por cima não conserta nenhum dos dois. Nos itens 1, 3 e 5, destrave e siga.

### 1. Resolva a identidade (SEM argumentos — usa o que esta sessão já registrou):
   - Windows: `PS "$ROOT\bin\bus-name.ps1"`
   - macOS/Linux: `bash "$ROOT/bin/bus-name.sh"`
   - Retornou `PROJECT=/SLUG=/BUS_CRON_INTERVAL=` → **guarde o `BUS_CRON_INTERVAL`** (intervalo do cron, default 5) e siga pro passo 2. Retornou `NONE` → esta sessão **nunca se registrou**; rode **`/bus <projeto> <slug>`** primeiro (sem identidade não dá pra re-armar) e pare.

### 2. Re-arme o cron DO ZERO
 `CronList`/`CronCreate`/`CronDelete` são **deferidas**: rode `ToolSearch select:CronList,CronCreate,CronDelete` ANTES.
   - **DESARMAR:** `CronList` → `CronDelete` em **CADA** job cujo prompt começa com `/bus` **ou** `bus-tick` (limpa phantom/duplicado — pós-restart o `CronList` pode listar um cron morto que **não dispara**; re-arme sempre do zero).
   - **ARMAR:** `CronCreate(cron: "*/<N> * * * *", recurring: true, prompt: <BUS_TICK_PROMPT>)`, onde **`<N>` = o `BUS_CRON_INTERVAL`** e **`<BUS_TICK_PROMPT>` = a linha `BUS_TICK_PROMPT=`** que o script devolveu no passo 1 — **copiada literal, sem reescrever o caminho**. **UM** cron, a cada `<N>` min, prompt de **TEXTO PURO** (nunca `/bus`: slash command expande a skill inteira no histórico a cada tique — ver SKILL do bus, passo 1). Texto puro também não expande `${CLAUDE_PLUGIN_ROOT}`: caminho montado na mão quebra o tique **em silêncio**. ⚠️ Só `*/N` ou valor único disparam — vírgula/`M/30` o harness aceita mas **NÃO dispara**.

### 3. Encerre

**NÃO** processe o inbox e **NÃO** mexa no lock — exceto o órfão em seu próprio nome, que o passo 0 já mandou liberar. Reporte **"cron re-armado — slug=X, projeto=Y"**. O auto-recheck (bare `/bus` a cada `<N>` min) volta a rodar e o dashboard mostra o especialista armado.
