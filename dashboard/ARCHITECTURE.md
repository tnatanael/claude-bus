# BUS Live Dashboard : Architecture (v1)

Owner: bus-demo-arquitect (architect). Build coordinated by bus-demo-po (PO).
Implemented by bus-demo-dev-backend (server) and bus-demo-dev-frontend (UI).

> **Atualização v2 (modelo pull).** O BUS abandonou o monitor de fundo: não há mais presença, heartbeat nem busy/free. No `GET /api/state` o campo `sessions[]` saiu — o dashboard lê só `handoffs` (inbox/processing/done/rejected) + `counts`; o **inbox** é a fila de pendentes (onde rodar `/bus`). A coluna `done` é filtrada na exibição (últimas 24h, máx 20, mais recente primeiro). As subpastas `presence/` e `state/` não são mais usadas. As seções abaixo descrevem o design v1 original (presença) e ficam por contexto histórico.

## Goal
A small, zero-build web app that visualizes the real claude-bus state on disk
(`/tmp/claude-bus`), making the skill's mechanics tangible: presence, busy/free
state, async handoffs moving across folders (inbox : processing : done), shared
secret auth (accepted vs rejected), and reply correlation via `in_reply_to`.

## Tech stack (chosen for zero install / zero build)
- Backend: Node.js, standard library only (`http`, `fs`, `path`). No npm
  dependencies, no framework. Runs with `node server.js`.
- Frontend: a single static `public/index.html` (HTML + CSS + vanilla JS in one
  file). No framework, no bundler, no build step. Served by the backend.
- Rationale: any session runs it immediately with just Node. Nothing to install,
  nothing to compile. Keeps the demo about the BUS, not the toolchain.

## Run
- App lives at: `/Users/thiagomarracini/Projects/bus-demo/`
- `node server.js` starts an HTTP server on `http://localhost:7878`.
- It serves the JSON API and the static UI from `public/`.
- BUS root resolved from env `CLAUDE_BUS_ROOT`, default `/tmp/claude-bus`.

## Project structure (file ownership : do not cross these lines)
```
bus-demo/
  server.js        <- bus-demo-dev-backend OWNS (Node http server: API + static public/)
  public/
    index.html     <- bus-demo-dev-frontend OWNS (dashboard UI)
  ARCHITECTURE.md  <- this file (architect)
  README.md        <- run instructions (PO or backend)
```
Backend touches `server.js` only. Frontend touches `public/` only. Neither edits
the other's files. There is no shared file that both write.

## SAFETY BOUNDARY (mandatory)
The dashboard is READ ONLY with respect to the BUS. The backend MUST NOT create,
move, modify, or delete anything under the BUS root. It only reads. We must never
disturb the live BUS that the sessions depend on.

## CONTRACT (backend provides, frontend consumes) : authoritative

### GET /api/state  -> 200 application/json
```json
{
  "now": 1781712345,
  "busRoot": "/tmp/claude-bus",
  "sessions": [
    { "slug": "bus-demo-po", "state": "free", "alive": true, "lastBeatAgeSec": 1 }
  ],
  "handoffs": {
    "inbox":      [ { "id": "...", "from": "...", "to": "...", "replyRequired": false, "inReplyTo": "" } ],
    "processing": [],
    "done":       [],
    "rejected":   []
  },
  "counts": { "inbox": 0, "processing": 0, "done": 6, "rejected": 0 }
}
```
Field semantics:
- `now`: server unix time in seconds.
- `sessions[]`: one entry per known session.
  - `slug`: session name.
  - `state`: `"busy"` | `"free"` | `"unknown"` (unknown when no state file maps).
  - `alive`: boolean, true when heartbeat age <= 120s.
  - `lastBeatAgeSec`: integer seconds since the last heartbeat.
- `handoffs.<folder>[]`: parsed from the files in that folder, newest first.
  Each item: `id`, `from`, `to`, `replyRequired` (bool), `inReplyTo` (string, "" if none).
- `counts`: file count per folder.

### GET /api/events  (Server-Sent Events) : OPTIONAL
- `Content-Type: text/event-stream`. Emit `data: <same JSON as /api/state>\n\n`
  when state changes, plus a heartbeat comment (`: ping\n\n`) every ~5s.
- Frontend MAY use SSE OR simply poll `/api/state` every 1500ms. Frontend's
  choice. Backend MUST provide `/api/state`; `/api/events` is a nice-to-have.

### How the backend derives the data (backend domain, documented so it matches reality)
BUS folders under the bus root: `presence/ state/ names/ inbox/ processing/ done/ rejected/`.
- Sessions:
  - `presence/<slug>.alive`: its mtime is the last heartbeat (use mtime, not content).
  - `names/`: maps a session id to a slug. `state/<sessionId>.state` holds `busy`/`free`.
    Use the name map to associate a slug with its state file. If no mapping/state,
    report `state: "unknown"`.
  - Build the session list from presence slugs (authoritative for who exists / alive),
    joined to state via the name map.
- Handoff files are named `to-<to>__from-<from>__<id>.handoff`. Parse `to`, `from`,
  `id` from the filename, and read the header lines (`id:`, `from:`, `to:`,
  `reply_required:`, `in_reply_to:`) from the file body for accuracy.
- Sort newest first by `id` (it is timestamp prefixed: `YYYYMMDD-HHMMSS-xxxxxx`).

## UI requirements (frontend)
- Auto-refresh: poll `/api/state` every ~1.5s (or use SSE). Show `now` ticking.
- P0 Presence board: a card/row per session with slug, a state badge
  (busy = amber, free = green, unknown = grey), an alive dot, and "last beat Ns ago".
- P0 Handoff flow: columns for inbox -> processing -> done (plus a rejected area),
  each handoff shown as `from -> to` with its id; visually link a reply to its
  parent via `inReplyTo`.
- P1 Auth indicator: surface the rejected count distinctly (rejected = failed
  shared secret auth).
- P2 (only if trivial, and only if PO prioritizes): a "send test handoff" button.
  This would be the ONLY write path and needs a dedicated backend POST endpoint
  that shells out to `bus-send.sh`. DEFER by default; keep it clearly separated.
- Clean and legible. No framework.

## Acceptance (P0)
With 2+ sessions on the BUS, the dashboard correctly shows their presence and
busy/free state, and a real handoff is visibly seen transiting inbox -> processing
-> done within the refresh window.
