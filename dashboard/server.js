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
// Default must match the scripts on every OS: .ps1 use %TEMP%, .sh hardcode
// /tmp/claude-bus. On macOS os.tmpdir() is $TMPDIR (/var/folders/.../T), NOT /tmp,
// so deriving from os.tmpdir() on Unix would read a different dir than the scripts
// write to. Use %TEMP% on Windows, /tmp/claude-bus on Unix. Override via CLAUDE_BUS_ROOT.
const BUS_ROOT = process.env.CLAUDE_BUS_ROOT
  || (process.platform === 'win32'
      ? path.join(require('os').tmpdir(), 'claude-bus')
      : '/tmp/claude-bus');
const PUBLIC_DIR = path.join(__dirname, 'public');

const HANDOFF_FOLDERS = ['inbox', 'processing', 'done', 'rejected'];
const DONE_MAX_AGE_SEC = 24 * 3600; // done view: hide handoffs older than 24h
const DONE_MAX_ITEMS = 20;          // done view: cap to the most recent N (newest first)
// Frescor do seen -> cor do chip. Cron */5: um especialista saudavel tica a cada ~5min.
// verde < 6min; amarelo 6-10min (perdeu ~1 ciclo); vermelho > 10min OU nunca visto (offline).
// Quem SEGURA o lock (trabalhando) e promovido a verde depois (markWorking): num turno longo
// o seen fica "velho" mas a sessao esta MAIS viva que nunca -- nao e offline.
const SEEN_GREEN_SEC = 6 * 60;
const SEEN_YELLOW_SEC = 10 * 60;
function seenStatus(ageSec) {
  if (ageSec == null) return 'red';
  if (ageSec <= SEEN_GREEN_SEC) return 'green';
  if (ageSec <= SEEN_YELLOW_SEC) return 'yellow';
  return 'red';
}

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

// Corpo "puro" do handoff: o texto entre a linha "---" e "###BUS-END" (sem tags/header).
function parseHandoffBody(text) {
  if (!text) return '';
  const m = text.match(/^---[ \t]*\r?\n([\s\S]*?)\r?\n?###BUS-END/m);
  if (m) return m[1].trim();
  const i = text.search(/^---[ \t]*$/m);
  if (i >= 0) return text.slice(i).replace(/^---[ \t]*\r?\n/, '').replace(/###BUS-END[\s\S]*$/, '').trim();
  return text.trim();
}

// Le TODOS os handoffs do projeto (4 pastas, done SEM filtro) com corpo -- base do thread.
function readAllForThread(root) {
  const items = [];
  for (const folder of HANDOFF_FOLDERS) {
    const dir = path.join(root, folder);
    for (const f of safeReaddir(dir)) {
      const fromName = parseHandoffFilename(f);
      if (!fromName) continue;
      const raw = safeReadText(path.join(dir, f));
      const header = parseHandoffHeader(raw);
      items.push({
        id: header.id || fromName.id,
        from: header.from || fromName.from,
        to: header.to || fromName.to,
        replyRequired: String(header.reply_required).toLowerCase() === 'true',
        inReplyTo: header.in_reply_to || '',
        folder,
        body: parseHandoffBody(raw),
      });
    }
  }
  return items;
}

// Thread = componente conexo (via in_reply_to, nao-direcionado) que contem targetId,
// ordenado cronologicamente (id e timestamp-prefixado) = ordem de precedencia.
function buildThread(root, targetId) {
  const items = readAllForThread(root);
  const byId = new Map(items.map(it => [it.id, it]));
  const adj = new Map();
  const link = (a, b) => { if (!adj.has(a)) adj.set(a, new Set()); adj.get(a).add(b); };
  for (const it of items) {
    if (it.inReplyTo && byId.has(it.inReplyTo)) { link(it.id, it.inReplyTo); link(it.inReplyTo, it.id); }
  }
  const seen = new Set([targetId]);
  const queue = [targetId];
  while (queue.length) {
    const cur = queue.shift();
    for (const nb of (adj.get(cur) || [])) if (!seen.has(nb)) { seen.add(nb); queue.push(nb); }
  }
  const thread = [...seen].filter(id => byId.has(id)).map(id => byId.get(id));
  thread.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  return thread.map(it => Object.assign({ isTarget: it.id === targetId }, it));
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

const RESERVED_DIRS = new Set(['inbox', 'processing', 'done', 'rejected', 'names', 'presence', 'state', 'seen']);

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
    // status do chip pela idade do seen/<sid> (verde/amarelo/vermelho). O holder do lock
    // e promovido a verde depois (markWorking) -- trabalhando != offline.
    let seenAgeSec = null;
    try {
      const st = fs.statSync(path.join(BUS_ROOT, 'seen', sid));
      seenAgeSec = Math.floor(Date.now() / 1000) - Math.floor(st.mtimeMs / 1000);
    } catch (_) {}
    (roster[proj] = roster[proj] || []).push({ slug, cron: cronMinuteForSid(sid), status: seenStatus(seenAgeSec), seenAgeSec });
  }
  for (const p of Object.keys(roster)) {
    const prio = readPriorities(p === 'default' ? BUS_ROOT : path.join(BUS_ROOT, p));   // 1x por projeto
    // NAO deduplica: ghosts (sid morto re-registrado) DEVEM aparecer no front como chip
    // offline -- e sintoma de resíduo no BUS. A raiz é resolvida na evicção do bus-name -Set.
    for (const s of roster[p]) s.prio = (s.slug in prio) ? prio[s.slug] : 1000;
    roster[p].sort((a, b) => a.slug.localeCompare(b.slug));
  }
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
  set.delete('default');   // 'default' foi removido -> nunca listado (projeto e obrigatorio)
  return [...set].sort();
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
// Prioridades do projeto (arquivo <projroot>/.priority, linhas "slug:N"; default 1000).
function readPriorities(root) {
  const map = {};
  const raw = safeReadText(path.join(root || BUS_ROOT, '.priority'));
  if (raw) for (const ln of raw.split(/\r?\n/)) {
    const i = ln.indexOf(':');
    if (i > 0) { const s = ln.slice(0, i).trim(); const n = parseInt(ln.slice(i + 1).trim(), 10); if (s && !isNaN(n)) map[s] = n; }
  }
  return map;
}

// Metadados de exibicao nos itens do INBOX: it.tick=true (o front mostra o eta no card),
// it.toArmed = se o cron do destino esta vivo (seen fresco), it.toPrio = prioridade do
// destino (default 1000; o front mostra badge quando != 1000).
function attachToCron(handoffs, specs, projRoot) {
  // statusMap[slug] = melhor (mais fresco) status entre os sids do slug: green > yellow > red.
  // (robusto a ghost+vivo coexistindo: o vivo manda.)
  const rank = { green: 3, yellow: 2, red: 1 };
  const statusMap = {};
  for (const s of (specs || [])) {
    if (!(s.slug in statusMap) || (rank[s.status] || 0) > (rank[statusMap[s.slug]] || 0)) statusMap[s.slug] = s.status;
  }
  const prio = readPriorities(projRoot);
  // toPrio (prioridade do destino) em TODOS os status -> o badge aparece certo em qualquer
  // card, nao so no inbox (antes, processing/done caiam no default 1000 no front).
  for (const status of ['inbox', 'processing', 'done', 'rejected']) {
    for (const it of (handoffs[status] || [])) it.toPrio = (it.to in prio) ? prio[it.to] : 1000;
  }
  // tick + toStatus/toArmed (eta "na fila"/"offline" + X vermelho) so faz sentido no INBOX.
  for (const it of (handoffs.inbox || [])) {
    it.tick = true;
    it.toStatus = (it.to in statusMap) ? statusMap[it.to] : null;      // null = destino nao registrado
    it.toArmed = it.toStatus == null ? null : (it.toStatus !== 'red'); // compat eta: offline (X) = red
  }
}

// Lock POR PROJETO (<projeto>/.bus-lock): quem esta "trabalhando agora" naquele projeto.
// Projetos diferentes tem locks independentes (rodam em paralelo). null se livre/expirado.
function readLockHolder(root) {
  try {
    const raw = safeReadText(path.join(root || BUS_ROOT, '.bus-lock'));
    if (!raw) return null;
    const L = JSON.parse(raw);
    const expSec = Math.floor(new Date(L.expiry).getTime() / 1000);
    if (!(Math.floor(Date.now() / 1000) < expSec)) return null;   // expirado => ninguem
    return { slug: L.slug || '?', project: L.project || 'default', since: L.since || null, expiry: L.expiry || null };
  } catch (_) { return null; }
}

// PAUSA por projeto: presenca do marcador <projeto>/.bus-paused. Enquanto pausado, o gate
// defere o processamento (bare /bus) daquele projeto -- sem interromper quem ja trabalha.
function readPaused(root) {
  try { return fs.existsSync(path.join(root, '.bus-paused')); } catch (_) { return false; }
}

// holder do lock daquele projeto = trabalhando AGORA -> status verde (sobrepoe o seen "velho"
// de um turno longo; trabalhando e o oposto de offline). Roda ANTES do attachToCron pra o
// destino working nao virar "offline" (X vermelho) num card do inbox.
function markWorking(specs, holder) {
  if (holder && holder.slug) for (const s of (specs || [])) if (s.slug === holder.slug) s.status = 'green';
}
function buildPayload(p) {
  p = p || 'all';
  const roster = readRoster();
  if (p === 'all') {
    const now = Math.floor(Date.now() / 1000);
    const projects = listProjects().map(name => {
      const st = buildState(projectRoot(name));
      const holder = readLockHolder(projectRoot(name));
      markWorking(roster[name] || [], holder);
      attachToCron(st.handoffs, roster[name] || [], projectRoot(name));
      return { project: name, specialists: roster[name] || [], handoffs: st.handoffs, counts: st.counts, holder, paused: readPaused(projectRoot(name)) };
    });
    return { now, all: true, projects, holders: projects.map(pr => pr.holder).filter(Boolean) };
  }
  const st = buildState(projectRoot(p));
  st.project = p;
  st.holder = readLockHolder(projectRoot(p));
  markWorking(roster[p] || [], st.holder);
  st.specialists = roster[p] || [];
  attachToCron(st.handoffs, roster[p] || [], projectRoot(p));
  st.paused = readPaused(projectRoot(p));
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

  if (req.method === 'GET' && urlPath === '/api/thread') {
    try {
      const proj = queryParam(req.url, 'project') || 'default';
      const id = queryParam(req.url, 'id');
      sendJson(res, { id, project: proj, thread: buildThread(projectRoot(proj), id) });
    } catch (e) {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: String(e) }));
    }
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

  // Unica ESCRITA do dashboard: liga/desliga a pausa de um projeto (marcador .bus-paused).
  // So toca esse marcador; nome do projeto validado (anti path-traversal).
  if (req.method === 'POST' && urlPath === '/api/pause') {
    let body = '';
    req.on('data', c => { body += c; if (body.length > 4096) req.destroy(); });
    req.on('end', () => {
      try {
        const d = JSON.parse(body || '{}');
        const proj = d.project;
        if (!proj || proj === 'all' || !/^[a-zA-Z0-9_-]+$/.test(proj)) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'valid project required' }));
          return;
        }
        const root = projectRoot(proj);
        const marker = path.join(root, '.bus-paused');
        if (d.paused) {
          try { fs.mkdirSync(root, { recursive: true }); } catch (_) {}
          fs.writeFileSync(marker, new Date().toISOString());
        } else {
          try { fs.unlinkSync(marker); } catch (_) {}
        }
        sendJson(res, { project: proj, paused: !!d.paused });
      } catch (e) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: String(e) }));
      }
    });
    return;
  }

  // Cancela um handoff do OPERADOR (via /bus-message) que ainda esta no INBOX -- caso o
  // operador mude de ideia. Guardrails: so from-operador, so no inbox (nao mexe em trabalho
  // de especialista nem no que ja foi pra processing/done), project+id validados (sem traversal).
  if (req.method === 'POST' && urlPath === '/api/cancel') {
    let body = '';
    req.on('data', c => { body += c; if (body.length > 4096) req.destroy(); });
    req.on('end', () => {
      try {
        const d = JSON.parse(body || '{}');
        const proj = d.project;
        const id = String(d.id || '');
        if (!proj || proj === 'all' || !/^[a-zA-Z0-9_-]+$/.test(proj) || !/^[a-zA-Z0-9_-]+$/.test(id)) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'valid project and id required' }));
          return;
        }
        const inbox = path.join(projectRoot(proj), 'inbox');
        let deleted = null;
        for (const f of (safeReaddir(inbox) || [])) {
          const parsed = parseHandoffFilename(f);
          if (parsed && parsed.id === id && parsed.from === 'operador') {
            try { fs.unlinkSync(path.join(inbox, f)); deleted = f; } catch (_) {}
            break;
          }
        }
        sendJson(res, { ok: !!deleted, id, deleted });
      } catch (e) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: String(e) }));
      }
    });
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
