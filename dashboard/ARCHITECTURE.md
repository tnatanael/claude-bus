# BUS Live Dashboard — Arquitetura

App web **read-only** que visualiza o estado do claude-bus no disco. Sem build, sem
dependências (Node stdlib: `http`, `fs`, `path`). `node server.js` sobe em `:7878`,
serve a API JSON e o `public/index.html` estático.

## SAFETY BOUNDARY (inegociável)
O dashboard é **READ ONLY** sobre o BUS: nunca cria, move, altera ou apaga nada sob a
raiz do BUS — só lê (`readdirSync` / `readFileSync` / `statSync`). Guard de path
traversal; qualquer método != GET → 405. A coluna `done` é filtrada **só na exibição**
(últimas 24h, máx 20), o disco nunca é alterado.

## Layout do BUS (por projeto)
Base: `CLAUDE_BUS_ROOT` (padrão `/tmp/claude-bus`). Cada projeto é um namespace isolado:
- `default` → a raiz base.
- `<p>` → `<base>/<p>/`.

Cada projeto tem `inbox/ processing/ done/ rejected/` (e seu `.bus-secret`). O `names/`
(registro sessão → projeto+slug) fica na **base**, global. Projetos são auto-descobertos:
subpastas da base que não sejam reservadas (`inbox processing done rejected names
presence state`) nem dotfiles, mais o `default`.

## Contrato da API

### `GET /api/projects`
```json
{ "projects": ["default", "acme", "..."] }
```
Sempre inclui `default`.

### `GET /api/state?project=<p|all>`  (padrão: `all`)
**Projeto único** (`project=<p>`):
```json
{
  "now": 1719000000,
  "project": "acme",
  "busRoot": "<raiz do projeto>",
  "specialists": [{ "slug": "frontend", "cron": 11, "armed": true }, "..."],
  "holder": { "slug": "frontend", "project": "acme", "since": "<iso>", "expiry": "<iso>" },
  "handoffs": { "inbox": [], "processing": [], "done": [], "rejected": [] },
  "counts": { "inbox": 0, "processing": 0, "done": 4, "rejected": 0 }
}
```
**Agrupado** (`project=all`):
```json
{ "now": 1719000000, "all": true,
  "holder": { "slug": "frontend", "project": "acme", "since": "<iso>", "expiry": "<iso>" },
  "projects": [ { "project": "default", "specialists": [], "handoffs": {}, "counts": {} }, "..." ] }
```
`specialists`: especialistas do projeto, cada um `{ slug, cron, armed }`. `armed` = o `/bus` da sessão foi visto nos últimos 90min (marcador `seen/<sid>`, regravado a cada `/bus`/tique do hook; como o cron dispara `/bus` a cada 5 min, frescor ⇒ cron vivo). Lidos do `names/` + `seen/`. (`cron` = minuto determinístico do sid; vestigial agora que o cron é `*/5` sem spread.) Os itens do `inbox` carregam **`tick: true`** (marca item de inbox → o front mostra o eta), **`toArmed`** (se o cron do destino está vivo) e **`toPrio`** (prioridade do destino, lida de `<projroot>/.priority`, default 1000) — o front mostra um countdown **global** (`próximo check`, ao lado dos chips — todos checam no mesmo tique de 5 min), por card "N na fila" (lock ocupado) ou "destino offline" (`toArmed=false`), e um **badge de prioridade** sempre ao lado do destino (`↓` cede a vez / `1000` neutro=default / `↑` fura a fila). A inbox é ordenada por **prioridade** (maior em cima), depois por tempo de espera.
**`holder`** (top-level, global — vale pros dois formatos): quem segura o **lock de concorrência** (`<base>/.bus-lock`, 1 por máquina; o limite de API é da conta, não do projeto) agora — `{ slug, project, since, expiry }`, ou `null` se livre/expirado. O `expiry` é o lease (auto-libera se a sessão cair).
Cada handoff: `{ id, from, to, replyRequired, inReplyTo }`, parseado do nome do arquivo
`to-<to>__from-<from>__<id>.handoff` e do cabeçalho do corpo. Ordem: mais novo primeiro
(o `id` é `YYYYMMDD-HHMMSS-xxxxxx`). O `done` já vem filtrado (24h, máx 20).

### `GET /api/events?project=<p|all>`  (SSE, opcional)
`text/event-stream`: emite `data: <mesmo JSON do /api/state>` quando o estado muda, mais
um `: ping` a cada ~5s. O front pode usar SSE **ou** simplesmente pollar `/api/state`
(é o que ele faz, a cada ~1.5s).

### `GET /api/thread?project=<p>&id=<id>`
A thread (conversa) que contém o handoff `id`: o **componente conexo** via `in_reply_to`
(grafo não-direcionado), lendo TODOS os handoffs do projeto (done **sem filtro**), cada
um com o **corpo puro** (texto entre `---` e `###BUS-END`). Ordenado por `id` (cronológico
= ordem de precedência).
```json
{ "id": "...", "project": "...",
  "thread": [ { "id", "from", "to", "folder", "replyRequired", "inReplyTo", "body", "isTarget" } ] }
```

## Frontend (`public/index.html`)
- Um arquivo (HTML + CSS + JS vanilla), sem framework, sem build.
- Popula o seletor via `/api/projects` e polla `/api/state?project=<selecionado>`.
- **Projeto único** → flow completo com os conectores de resposta. **"Todos"** → uma
  seção por projeto (colunas, sem conectores).
- **Lock**: linha no header com o `holder` ("Trabalhando agora: slug · lease expira ~Nm") + popover (`!`) explicando o lock. Chips ordenados por **MRU do lock** (último dono à esquerda; persiste em `localStorage`). Inbox ordenada pelo **próximo tick** do destino (mais próximo no topo). Filtro de projeto persiste no F5 (`localStorage`).
