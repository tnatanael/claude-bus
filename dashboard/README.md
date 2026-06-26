# BUS Live Dashboard

App web minúsculo (sem build, sem dependências — só a stdlib do Node) que visualiza o claude-bus em tempo real, **read-only**, com **escopo de projeto**.

## Rodar

```
node dashboard/server.js
```

Abre em `http://localhost:7878`. Sem `npm install`: usa só `http`, `fs`, `path`.

- Porta: env `PORT` (padrão `7878`).
- Raiz do BUS: env `CLAUDE_BUS_ROOT` (padrão `/tmp/claude-bus`).

## O que ele mostra

- **Seletor de projeto** (no topo): escolha um projeto pra ver só o BUS dele, ou **"Todos"** pra ver todos agrupados (uma seção por projeto). Cada projeto é um namespace isolado: `default` = raiz base; `<p>` = `<base>/<p>`.
- **Especialistas registrados**: cada projeto mostra, em chips, os slugs registrados nele (do `names/`) — quem está naquela frente. Um **ponto** no chip indica se o cron daquele especialista está **armado** (verde — `/bus` visto na última ~1h) ou **offline** (vermelho — sessão fechada ou cron não confirmado). Os chips são ordenados por **MRU do lock**: quem pegou o lock por último fica mais à esquerda (a ordem persiste no F5); quem nunca pegou segue a regra antiga (offline à esquerda, online à direita).
- **Trabalhando agora** (linha no topo): quando alguém segura o **lock de concorrência** global, mostra `🔒 Trabalhando agora: <slug> (<projeto>) · lease expira ~Nm` + um popover (`!`) explicando o lock (1 por vez na conta, os outros deferem sem custo de API). Senão, `🔓 lock livre`.
- **Handoff flow**: colunas `inbox → processing → done` (+ a área de rejeitados). O **inbox** são os pendentes — rode `/bus` no destino de cada card pra processá-los; é **ordenado por prioridade do destino** (maior em cima = processa antes; PO/low-prio afunda) e, dentro da mesma prioridade, por tempo de espera (mais antigo no topo). Todos os crons disparam **a cada 1 min, no mesmo tique**, então o countdown é **global** (`⏱ próximo check`, ao lado dos chips de especialistas) — não por card. Cada card mostra **há quanto tempo está na fila**: **`⏳ na fila há Xm Ys`** (tempo desde que o handoff chegou, ainda não pego — normal sob carga) ou **`⚠ destino offline · há …`** (o cron do destino nem está disparando — vermelho, acionável: rode `/bus` nele). O destino (em destaque) ganha **sempre** um badge de prioridade — `↓N` (cede a vez, ex.: PO=`0`), `1000` neutro (default) ou `↑N` (fura a fila). Na visão de **projeto único**, conectores SVG ligam cada resposta ao handoff pai (`in_reply_to`). A coluna `done` mostra só as últimas 24h (máx 20, mais recente no topo) — filtro de exibição, o disco não é tocado.
- **Clique num card** → modal com o **corpo puro** do handoff (sem as tags `###BUS-START/END`/header) e, à esquerda, a **thread relacionada** (todos os handoffs ligados por `in_reply_to`, em ordem de precedência) — pra ler a conversa inteira em ordem. Fecha com Esc ou clicando fora.
- **Auth**: contador de rejeitados (handoffs sem token válido foram pra quarentena).
- **LIVE / MOCK / DOWN**: usa dados mock só até o backend responder pela 1ª vez; depois disso nunca finge dado (vira DOWN se o backend cair).

## Rodar sempre online (Windows)

Pra deixar o dashboard sempre de pé em `http://localhost:7878` (sem terminal aberto), coloque um launcher que sobe o `node server.js` **escondido** na pasta **Startup** do usuário (`shell:startup`) — ele sobe a cada logon. Ex. (`.vbs`):

```vbs
CreateObject("Wscript.Shell").Run """C:\caminho\node.exe"" ""C:\...\dashboard\server.js""", 0, False
```

Rode-o uma vez pra iniciar na hora. (Tarefa Agendada também serve, mas exige permissão; a pasta Startup não.)

## Read only (importante)

O servidor é **estritamente somente leitura** sobre o BUS: nunca cria, move, altera ou apaga nada sob a raiz do BUS (só `readdirSync` / `readFileSync` / `statSync`). Tem guard de path traversal, e qualquer método que não seja GET responde 405. O contrato completo da API está em [`ARCHITECTURE.md`](ARCHITECTURE.md).
