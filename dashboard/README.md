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
- **Especialistas registrados**: cada projeto mostra, em chips, os slugs registrados nele (do `names/`) — quem está naquela frente.
- **Handoff flow**: colunas `inbox → processing → done` (+ a área de rejeitados). O **inbox** são os pendentes — rode `/bus` no destino de cada card pra processá-los; cada card do inbox traz um **countdown** (`⏱ ~Nm`) até o cron do especialista **destino** pegá-lo. Na visão de **projeto único**, conectores SVG ligam cada resposta ao handoff pai (`in_reply_to`). A coluna `done` mostra só as últimas 24h (máx 20, mais recente no topo) — filtro de exibição, o disco não é tocado.
- **Auth**: contador de rejeitados (handoffs sem token válido foram pra quarentena).
- **LIVE / MOCK / DOWN**: usa dados mock só até o backend responder pela 1ª vez; depois disso nunca finge dado (vira DOWN se o backend cair).

## Read only (importante)

O servidor é **estritamente somente leitura** sobre o BUS: nunca cria, move, altera ou apaga nada sob a raiz do BUS (só `readdirSync` / `readFileSync` / `statSync`). Tem guard de path traversal, e qualquer método que não seja GET responde 405. O contrato completo da API está em [`ARCHITECTURE.md`](ARCHITECTURE.md).
