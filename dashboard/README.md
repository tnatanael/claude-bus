# BUS Live Dashboard

App web minúsculo (sem build, sem dependências) que visualiza o estado real do claude-bus no disco: os handoffs transitando por `inbox` → `processing` → `done` (o **inbox** são os pendentes — onde rodar `/bus`), com correlação visual de respostas (`in_reply_to`) e indicador de autenticação (rejeitados).

Ele foi construído pelo próprio BUS (várias sessões-especialistas coordenando por handoffs), então o dashboard literalmente mostra a si mesmo sendo feito.

## Rodar

```
node dashboard/server.js
```

Abre em `http://localhost:7878`. Sem `npm install`: usa só a stdlib do Node (`http`, `fs`, `path`).

- Porta: env `PORT` (padrão `7878`).
- Raiz do BUS: env `CLAUDE_BUS_ROOT` (padrão `/tmp/claude-bus`).

## O que ele mostra

- **Handoff flow**: colunas `inbox -> processing -> done` (mais a área de `rejected`), cada handoff como `from -> to` com seu id; conectores SVG ligam cada resposta ao handoff pai por `in_reply_to`. O **inbox** são os pendentes — rode `/bus` no destino de cada card pra processá-los. Não há mais presença/heartbeat: sem monitor de fundo, uma sessão só processa quando você roda `/bus` (ou o cron horário de auto-recheck disparar). A coluna `done` mostra só as últimas 24h (máx 20, mais recente no topo).
- **Auth**: contador de rejeitados (handoffs sem token válido foram para a quarentena).
- **LIVE / MOCK / DOWN**: a UI usa dados mock só até o backend responder pela primeira vez; depois disso nunca finge dado (vira DOWN se o backend cair).

## Read only (importante)

O servidor é **estritamente somente leitura** sobre o BUS: nunca cria, move, altera ou apaga nada sob a raiz do BUS (só `readdirSync` / `readFileSync` / `statSync`). Tem guard de path traversal, e qualquer método que não seja GET responde 405. O contrato completo da API (`GET /api/state` e o `GET /api/events` por SSE) está em [`ARCHITECTURE.md`](ARCHITECTURE.md).
