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
{ "projects": ["default", "petadata", "..."] }
```
Sempre inclui `default`.

### `GET /api/state?project=<p|all>`  (padrão: `all`)
**Projeto único** (`project=<p>`):
```json
{
  "now": 1719000000,
  "project": "petadata",
  "busRoot": "<raiz do projeto>",
  "handoffs": { "inbox": [], "processing": [], "done": [], "rejected": [] },
  "counts": { "inbox": 0, "processing": 0, "done": 4, "rejected": 0 }
}
```
**Agrupado** (`project=all`):
```json
{ "now": 1719000000, "all": true,
  "projects": [ { "project": "default", "handoffs": {}, "counts": {} }, "..." ] }
```
Cada handoff: `{ id, from, to, replyRequired, inReplyTo }`, parseado do nome do arquivo
`to-<to>__from-<from>__<id>.handoff` e do cabeçalho do corpo. Ordem: mais novo primeiro
(o `id` é `YYYYMMDD-HHMMSS-xxxxxx`). O `done` já vem filtrado (24h, máx 20).

### `GET /api/events?project=<p|all>`  (SSE, opcional)
`text/event-stream`: emite `data: <mesmo JSON do /api/state>` quando o estado muda, mais
um `: ping` a cada ~5s. O front pode usar SSE **ou** simplesmente pollar `/api/state`
(é o que ele faz, a cada ~1.5s).

## Frontend (`public/index.html`)
- Um arquivo (HTML + CSS + JS vanilla), sem framework, sem build.
- Popula o seletor via `/api/projects` e polla `/api/state?project=<selecionado>`.
- **Projeto único** → flow completo com os conectores de resposta. **"Todos"** → uma
  seção por projeto (colunas, sem conectores).
