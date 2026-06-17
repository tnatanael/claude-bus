'use strict';

/*
 * BUS Live Dashboard : backend (owned by bus-demo-dev-backend).
 *
 * Node.js standard library only (http, fs, path). No npm, no framework, no build.
 * Run: `node server.js` -> HTTP server on http://localhost:7878
 *   - GET /api/state  : JSON snapshot of the live BUS (see ARCHITECTURE.md contract)
 *   - GET /api/events : Server-Sent Events stream of the same JSON (optional, cheap)
 *   - everything else : static files from public/ (frontend's domain)
 *
 * SAFETY BOUNDARY (non-negotiable): this server is READ ONLY against the BUS root.
 * It never creates, moves, modifies, or deletes anything under the BUS root. Only
 * fs read calls (readdirSync / readFileSync / statSync) are used against it.
 */

const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = Number(process.env.PORT) || 7878;
const BUS_ROOT = process.env.CLAUDE_BUS_ROOT || '/tmp/claude-bus';
const PUBLIC_DIR = path.join(__dirname, 'public');

const ALIVE_MAX_AGE_SEC = 120; // heartbeat older than this => not alive
const HANDOFF_FOLDERS = ['inbox', 'processing', 'done', 'rejected'];

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
};

// ---------------------------------------------------------------------------
// BUS readers (READ ONLY). Every read is defensive: a missing or malformed file
// must never crash the API, it just degrades that one entry.
// ---------------------------------------------------------------------------

function safeReaddir(dir) {
  try {
    return fs.readdirSync(dir);
  } catch (_) {
    return [];
  }
}

function safeReadText(file) {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch (_) {
    return null;
  }
}

// names/<sessionId>.txt -> slug. Returns { slugToSessionId, sessionIdToSlug }.
function readNameMaps() {
  const slugToSessionId = {};
  const sessionIdToSlug = {};
  for (const f of safeReaddir(path.join(BUS_ROOT, 'names'))) {
    if (!f.endsWith('.txt')) continue;
    const sessionId = f.slice(0, -'.txt'.length);
    const slug = (safeReadText(path.join(BUS_ROOT, 'names', f)) || '').trim();
    if (!slug) continue;
    sessionIdToSlug[sessionId] = slug;
    slugToSessionId[slug] = sessionId; // last writer wins; one slug == one live session
  }
  return { slugToSessionId, sessionIdToSlug };
}

// state/<sessionId>.state -> "busy" | "free"
function readStateMap() {
  const map = {};
  for (const f of safeReaddir(path.join(BUS_ROOT, 'state'))) {
    if (!f.endsWith('.state')) continue;
    const sessionId = f.slice(0, -'.state'.length);
    const v = (safeReadText(path.join(BUS_ROOT, 'state', f)) || '').trim();
    if (v) map[sessionId] = v;
  }
  return map;
}

// presence/<slug>.alive : mtime is the last heartbeat. The heartbeat is kept fresh
// both by the monitor (while idle) and by a PostToolUse hook (while the session is
// actively working but its monitor has exited), so `alive` is a reliable signal of
// "in the BUS and/or working".
function readSessions(now) {
  const { slugToSessionId } = readNameMaps();
  const stateMap = readStateMap();
  const presenceDir = path.join(BUS_ROOT, 'presence');
  const sessions = [];

  for (const f of safeReaddir(presenceDir)) {
    if (!f.endsWith('.alive')) continue;
    const slug = f.slice(0, -'.alive'.length);
    let lastBeatAgeSec = null;
    try {
      const st = fs.statSync(path.join(presenceDir, f));
      lastBeatAgeSec = Math.max(0, now - Math.floor(st.mtimeMs / 1000));
    } catch (_) {
      continue;
    }
    const sessionId = slugToSessionId[slug];
    const state = (sessionId && stateMap[sessionId]) ? stateMap[sessionId] : 'unknown';
    // presence/<slug>.ver : version stamped by the monitor on startup (v0.4.1+).
    const version = (safeReadText(path.join(presenceDir, slug + '.ver')) || '').trim() || null;
    sessions.push({
      slug,
      state,
      version,
      alive: lastBeatAgeSec <= ALIVE_MAX_AGE_SEC,
      lastBeatAgeSec,
    });
  }

  sessions.sort((a, b) => a.slug.localeCompare(b.slug));
  return sessions;
}

// Filename: to-<to>__from-<from>__<id>.handoff  (slugs contain hyphens; the "__"
// double underscore is the field separator). Header in the body is authoritative
// for reply_required / in_reply_to.
function parseHandoffFilename(name) {
  if (!name.endsWith('.handoff')) return null;
  const base = name.slice(0, -'.handoff'.length);
  const parts = base.split('__');
  if (parts.length < 3) return null;
  const to = parts[0].startsWith('to-') ? parts[0].slice(3) : parts[0];
  const from = parts[1].startsWith('from-') ? parts[1].slice(5) : parts[1];
  const id = parts.slice(2).join('__');
  return { id, from, to };
}

function parseHandoffHeader(text) {
  const out = {};
  if (!text) return out;
  const lines = text.split(/\r?\n/);
  for (const line of lines) {
    if (line === '---' || line.startsWith('###BUS-END')) break; // header ends at the divider
    const m = line.match(/^([a-z_]+):\s?(.*)$/);
    if (m) out[m[1]] = m[2].trim();
  }
  return out;
}

function readHandoffs(folder) {
  const dir = path.join(BUS_ROOT, folder);
  const items = [];
  for (const f of safeReaddir(dir)) {
    const fromName = parseHandoffFilename(f);
    if (!fromName) continue;
    const header = parseHandoffHeader(safeReadText(path.join(dir, f)));
    items.push({
      id: header.id || fromName.id,
      from: header.from || fromName.from,
      to: header.to || fromName.to,
      replyRequired: String(header.reply_required).toLowerCase() === 'true',
      inReplyTo: header.in_reply_to || '',
    });
  }
  // Newest first: id is timestamp prefixed (YYYYMMDD-HHMMSS-xxxxxx).
  items.sort((a, b) => (a.id < b.id ? 1 : a.id > b.id ? -1 : 0));
  return items;
}

function buildState() {
  const now = Math.floor(Date.now() / 1000);
  const handoffs = {};
  const counts = {};
  for (const folder of HANDOFF_FOLDERS) {
    const items = readHandoffs(folder);
    handoffs[folder] = items;
    counts[folder] = items.length;
  }
  return {
    now,
    busRoot: BUS_ROOT,
    sessions: readSessions(now),
    handoffs,
    counts,
  };
}

// ---------------------------------------------------------------------------
// Static serving (public/ is the frontend's domain). If public/index.html is not
// there yet, serve an in-memory placeholder for "/" : we never write to disk.
// ---------------------------------------------------------------------------

const PLACEHOLDER = `<!doctype html><html><head><meta charset="utf-8">
<title>BUS Live Dashboard</title></head><body style="font-family:system-ui;padding:2rem">
<h1>BUS Live Dashboard : backend up</h1>
<p>The API is live. The UI (public/index.html) has not landed yet.</p>
<p>Try <a href="/api/state">/api/state</a>.</p>
</body></html>`;

function serveStatic(req, res) {
  let urlPath;
  try {
    urlPath = decodeURIComponent((req.url.split('?')[0]) || '/');
  } catch (_) {
    res.writeHead(400, { 'Content-Type': 'text/plain' });
    res.end('Bad request');
    return;
  }
  if (urlPath === '/') urlPath = '/index.html';

  const resolved = path.normalize(path.join(PUBLIC_DIR, urlPath));
  // Path traversal guard: must stay within PUBLIC_DIR.
  if (resolved !== PUBLIC_DIR && !resolved.startsWith(PUBLIC_DIR + path.sep)) {
    res.writeHead(403, { 'Content-Type': 'text/plain' });
    res.end('Forbidden');
    return;
  }

  fs.readFile(resolved, (err, data) => {
    if (err) {
      if (urlPath === '/index.html') {
        res.writeHead(200, { 'Content-Type': MIME['.html'] });
        res.end(PLACEHOLDER);
        return;
      }
      res.writeHead(404, { 'Content-Type': 'text/plain' });
      res.end('Not found');
      return;
    }
    const type = MIME[path.extname(resolved)] || 'application/octet-stream';
    res.writeHead(200, { 'Content-Type': type });
    res.end(data);
  });
}

// ---------------------------------------------------------------------------
// HTTP server
// ---------------------------------------------------------------------------

function sendJson(res, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(200, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
  });
  res.end(body);
}

function handleEvents(req, res) {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-store',
    Connection: 'keep-alive',
  });

  let lastPayload = '';
  const tick = () => {
    let payload;
    try {
      payload = JSON.stringify(buildState());
    } catch (_) {
      return;
    }
    if (payload !== lastPayload) {
      lastPayload = payload;
      res.write(`data: ${payload}\n\n`);
    }
  };

  tick(); // push current state immediately
  const dataTimer = setInterval(tick, 1500);
  const pingTimer = setInterval(() => res.write(': ping\n\n'), 5000);

  const cleanup = () => {
    clearInterval(dataTimer);
    clearInterval(pingTimer);
  };
  req.on('close', cleanup);
  res.on('error', cleanup);
}

const server = http.createServer((req, res) => {
  const urlPath = (req.url || '/').split('?')[0];

  if (req.method === 'GET' && urlPath === '/api/state') {
    try {
      sendJson(res, buildState());
    } catch (e) {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'failed to build state', detail: String(e) }));
    }
    return;
  }

  if (req.method === 'GET' && urlPath === '/api/events') {
    handleEvents(req, res);
    return;
  }

  if (req.method === 'GET' || req.method === 'HEAD') {
    serveStatic(req, res);
    return;
  }

  res.writeHead(405, { 'Content-Type': 'text/plain' });
  res.end('Method not allowed');
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`BUS Live Dashboard backend listening on http://localhost:${PORT}`);
  console.log(`BUS root (read only): ${BUS_ROOT}`);
});
