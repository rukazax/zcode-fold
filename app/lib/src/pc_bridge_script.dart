/// Self-contained read-only file bridge, written to `%TEMP%` and started by
/// the desktop terminal during one-tap PC setup. Deliberately dependency-free
/// (Node core only), so it works on any PC with ZCode — no repo/tools needed.
///
/// Protocol: `GET /health`, `GET /fs/list?path=`, `GET /fs/read?path=`.
/// Bearer token lives in `%TEMP%\zcode-fold-bridge.token`; root is the whole
/// system drive; reads are capped at 8 MB.
const pcBridgeServerScript = r'''
const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const net = require('net');
const crypto = require('crypto');

const PORT = 8940;
const ROOT = 'C:/';
const tokenFile = path.join(os.tmpdir(), 'zcode-fold-bridge.token');
let token = '';
try { token = fs.readFileSync(tokenFile, 'utf8').trim(); } catch (e) {}
if (!token) {
  token = crypto.randomBytes(16).toString('base64url');
  try { fs.writeFileSync(tokenFile, token, 'utf8'); } catch (e) {}
}

function ips() {
  const out = new Set();
  for (const list of Object.values(os.networkInterfaces())) {
    for (const i of list || []) {
      if (i && i.family === 'IPv4' && !i.internal && net.isIPv4(i.address) && !i.address.startsWith('169.254.')) {
        out.add(i.address);
      }
    }
  }
  return [...out];
}

function safePath(requested) {
  const resolved = path.resolve(ROOT, requested || '');
  const rel = path.relative(ROOT, resolved);
  if (rel.startsWith('..') || path.isAbsolute(rel)) return null;
  return resolved;
}

const types = {
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
  '.gif': 'image/gif', '.webp': 'image/webp', '.svg': 'image/svg+xml',
  '.pdf': 'application/pdf', '.json': 'application/json',
};

const server = http.createServer((req, res) => {
  if (req.headers.authorization !== 'Bearer ' + token) {
    res.writeHead(401).end('bridge: bad token');
    return;
  }
  const url = new URL(req.url, 'http://127.0.0.1');
  if (url.pathname === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, root: ROOT, name: os.hostname() }));
    return;
  }
  if (url.pathname === '/fs/list') {
    const target = safePath(url.searchParams.get('path') || '');
    if (!target) { res.writeHead(403).end('outside root'); return; }
    try {
      const entries = fs.readdirSync(target, { withFileTypes: true })
        .filter((e) => !e.name.startsWith('.'))
        .map((e) => {
          const full = path.join(target, e.name);
          let size = 0;
          try { if (e.isFile()) size = fs.statSync(full).size; } catch (err) {}
          return { name: e.name, path: full, dir: e.isDirectory(), size };
        })
        .sort((a, b) => a.dir === b.dir ? a.name.localeCompare(b.name) : (a.dir ? -1 : 1))
        .slice(0, 500);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ path: target, root: ROOT, entries }));
    } catch (e) {
      res.writeHead(400).end('list failed: ' + e.message);
    }
    return;
  }
  if (url.pathname === '/fs/read') {
    const target = safePath(url.searchParams.get('path') || '');
    if (!target) { res.writeHead(403).end('outside root'); return; }
    try {
      const stat = fs.statSync(target);
      if (!stat.isFile()) { res.writeHead(400).end('not a file'); return; }
      if (stat.size > 8 * 1024 * 1024) {
        res.writeHead(413).end('file too large (8 MB)');
        return;
      }
      const ext = path.extname(target).toLowerCase();
      res.writeHead(200, {
        'Content-Type': types[ext] || 'application/octet-stream',
        'Content-Length': stat.size,
      });
      fs.createReadStream(target).pipe(res);
    } catch (e) {
      res.writeHead(404).end('read failed: ' + e.message);
    }
    return;
  }
  res.writeHead(404).end('bridge: unknown path');
});

function announce() {
  const urls = ips().map((ip) => 'http://' + ip + ':' + PORT);
  console.log('BRIDGE_READY ' + JSON.stringify({
    url: urls[0] || ('http://127.0.0.1:' + PORT),
    urls,
    token,
  }));
}

server.listen(PORT, '0.0.0.0', () => {
  console.log('ZCode Fold bridge, root=' + ROOT + ', port=' + PORT);
  announce();
});
server.on('error', (e) => {
  if (e && e.code === 'EADDRINUSE') {
    announce();
    setTimeout(() => process.exit(0), 200);
    return;
  }
  throw e;
});
''';
