'use strict';

/*
 * BUS Live Dashboard : backend.
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

const HANDOFF_FOLDERS = ['inbox', 'processing', 'done', 'rejected'];
const DONE_MAX_AGE_SEC = 24 * 3600; // done view: hide handoffs older than 24h
const DONE_MAX_ITEMS = 20;          // done view: cap to the most recent N (newest first)

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

function readHandoffs(folder, root) {
  const dir = path.join(root || BUS_ROOT, folder);
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

// Timestamp prefix of a handoff id (YYYYMMDD-HHMMSS-xxxxxx) -> epoch seconds (local
// time, matching how the sender stamps it). null if it doesn't parse.
function idToEpochSec(id) {
  const m = /^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})/.exec(id || '');
  if (!m) return null;
  return Math.floor(new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]).getTime() / 1000);
}

function buildState(root) {
  root = root || BUS_ROOT;
  const now = Math.floor(Date.now() / 1000);
  const handoffs = {};
  const counts = {};
  for (const folder of HANDOFF_FOLDERS) {
    let items = readHandoffs(folder, root);
    if (folder === 'done') {
      // Self-cleaning VIEW (the BUS on disk is never touched -- read-only boundary):
      // show only the last 24h, newest first, capped to the most recent 20.
      const cutoff = now - DONE_MAX_AGE_SEC;
      items = items
        .filter(it => { const t = idToEpochSec(it.id); return t === null || t >= cutoff; })
        .slice(0, DONE_MAX_ITEMS);
    }
    handoffs[folder] = items;
    counts[folder] = items.length;
  }
  return {
    now,
    busRoot: root,
    handoffs,
    counts,
  };
}

// --- Projects ------------------------------------------------------------
// Each project is an isolated BUS namespace. 'default' = the base root (flat,
// backward-compatible); a named project <p> = <base>/<p> with its own folders.
function projectRoot(p) {
  return (!p || p === 'default') ? BUS_ROOT : path.join(BUS_ROOT, p);
}

const RESERVED_DIRS = new Set(['inbox', 'processing', 'done', 'rejected', 'names', 'presence', 'state']);

// Minuto do cron de uma sessao = soma dos bytes do sid mod 60 (mesmo calculo do
// bus-name), pro countdown do dashboard bater com o minuto realmente armado.
function cronMinuteForSid(sid) {
  let s = 0;
  for (let i = 0; i < sid.length; i++) s += sid.charCodeAt(i);
  return s % 60;
}

// names/<sid>.txt = 2 linhas (projeto, slug). Roster: projeto -> [{slug, cron}].
// (compat: arquivo de 1 linha = projeto 'default'.)
function readRoster() {
  const roster = {};
  for (const f of safeReaddir(path.join(BUS_ROOT, 'names'))) {
    if (!f.endsWith('.txt')) continue;
    const sid = f.slice(0, -'.txt'.length);
    const lines = (safeReadText(path.join(BUS_ROOT, 'names', f)) || '').split(/\r?\n/);
    let proj = '', slug = '';
    if (lines.length >= 2 && lines[1].trim() !== '') { proj = lines[0].trim(); slug = lines[1].trim(); }
    else if ((lines[0] || '').trim() !== '') { proj = 'default'; slug = lines[0].trim(); }
    else continue;
    if (!proj) proj = 'default';
    (roster[proj] = roster[proj] || []).push({ slug, cron: cronMinuteForSid(sid) });
  }
  for (const p of Object.keys(roster)) roster[p].sort((a, b) => a.slug.localeCompare(b.slug));
  return roster;
}

// Projects: 'default' + base subdirs (nao reservadas/dotfiles) + projetos do roster.
function listProjects() {
  const set = new Set();
  for (const name of safeReaddir(BUS_ROOT)) {
    if (RESERVED_DIRS.has(name) || name.startsWith('.')) continue;
    let isDir = false;
    try { isDir = fs.statSync(path.join(BUS_ROOT, name)).isDirectory(); } catch (_) {}
    if (isDir) set.add(name);
  }
  for (const p of Object.keys(readRoster())) set.add(p);
  set.delete('default');
  return ['default', ...[...set].sort()];
}

function queryParam(reqUrl, key) {
  const q = (reqUrl || '').split('?')[1] || '';
  for (const pair of q.split('&')) {
    const eq = pair.indexOf('=');
    const k = eq < 0 ? pair : pair.slice(0, eq);
    const v = eq < 0 ? '' : pair.slice(eq + 1);
    try { if (decodeURIComponent(k) === key) return decodeURIComponent(v); } catch (_) {}
  }
  return '';
}

// project='all' -> grouped { now, all:true, projects:[{project,handoffs,counts}] }
// project=<p>   -> single  { now, project, busRoot, handoffs, counts }
// Anexa a cada handoff do inbox o minuto do cron do DESTINO (it.to) -> it.toCron.
// E quando o especialista destino vai pegar o handoff (countdown no card do inbox).
function attachToCron(handoffs, specs) {
  const map = {};
  for (const s of (specs || [])) if (!(s.slug in map)) map[s.slug] = s.cron;
  for (const it of (handoffs.inbox || [])) it.toCron = (it.to in map) ? map[it.to] : null;
}

function buildPayload(p) {
  p = p || 'all';
  const roster = readRoster();
  if (p === 'all') {
    const now = Math.floor(Date.now() / 1000);
    const projects = listProjects().map(name => {
      const st = buildState(projectRoot(name));
      attachToCron(st.handoffs, roster[name] || []);
      return { project: name, specialists: roster[name] || [], handoffs: st.handoffs, counts: st.counts };
    });
    return { now, all: true, projects };
  }
  const st = buildState(projectRoot(p));
  st.project = p;
  st.specialists = roster[p] || [];
  attachToCron(st.handoffs, roster[p] || []);
  return st;
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
  const proj = queryParam(req.url, 'project') || 'all';
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-store',
    Connection: 'keep-alive',
  });

  let lastPayload = '';
  const tick = () => {
    let payload;
    try {
      payload = JSON.stringify(buildPayload(proj));
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

  if (req.method === 'GET' && urlPath === '/api/projects') {
    try { sendJson(res, { projects: listProjects() }); }
    catch (e) { res.writeHead(500, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ error: String(e) })); }
    return;
  }

  if (req.method === 'GET' && urlPath === '/api/state') {
    try {
      sendJson(res, buildPayload(queryParam(req.url, 'project')));
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
