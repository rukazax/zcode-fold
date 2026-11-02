// ZCode Fold — desktop bridge.
//
// Two jobs, one server:
//  1) handing the desktop Z.ai account token to the phone over the LAN
//     (one-time PIN, the bridge exits right after);
//  2) (--serve) a long-lived read-only file browser for the project, so the
//     phone can list/open files from this computer without extra tooling.
//
// Usage:
//   node bridge.mjs                      one-shot credentials handover
//   node bridge.mjs --serve [--root DIR] long-lived file API (token in
//                                        ./bridge-fs.token, printed at start)
//
// Security: LAN only, bearer token, paths are restricted to the root folder.

import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import QRCode from 'qrcode';

const args = process.argv.slice(2);
const serveMode = args.includes('--serve');
const rootArg = args.includes('--root') ? args[args.indexOf('--root') + 1] : null;
// File mode defaults to the whole system drive: the phone opens the project
// folder by default but can still browse the rest of the PC. Pass --root to
// narrow it (e.g. --root C:/Users/me/project).
const ROOT = path.resolve(
  rootArg ?? (serveMode ? path.parse(process.cwd()).root : process.cwd()),
);
const portArg = args.includes('--port') ? args[args.indexOf('--port') + 1] : null;
const PORT = portArg ? Number(portArg) : 8939;
if (!Number.isInteger(PORT) || PORT <= 0 || PORT > 65535) {
  throw new Error(`invalid --port: ${portArg}`);
}

function dec(raw) {
  const s = String(raw).replace(/^enc:v1:/, '').split('.');
  const iv = Buffer.from(s[0], 'base64url');
  const tag = Buffer.from(s[1], 'base64url');
  const data = Buffer.from(s[2], 'base64url');
  const secret =
    process.env.ZCODE_CREDENTIAL_SECRET ||
    `zcode-credential-fallback:${os.platform()}:${os.homedir()}:${os.userInfo().username}`;
  const key = crypto.createHash('sha256').update(secret).digest();
  const d = crypto.createDecipheriv('aes-256-gcm', key, iv);
  d.setAuthTag(tag);
  return Buffer.concat([d.update(data), d.final()]).toString('utf8');
}

function lanIps() {
  const ifaces = Object.values(os.networkInterfaces()).flat();
  const seen = new Set();
  for (const i of ifaces) {
    if (i?.family !== 'IPv4' || i.internal || !net.isIPv4(i.address)) continue;
    if (i.address.startsWith('169.254.')) continue;
    seen.add(i.address);
  }
  return [...seen];
}

const LAN_IPS = lanIps();
const LAN = LAN_IPS[0] ?? '127.0.0.1';

// ---------------------------------------------------------------------------
// Mode 2: long-lived read-only file API (--serve)
// ---------------------------------------------------------------------------

function safePath(requested) {
  if (!requested) return ROOT;
  const resolved = path.resolve(ROOT, requested);
  const rel = path.relative(ROOT, resolved);
  if (rel.startsWith('..') || path.isAbsolute(rel)) return null;
  return resolved;
}

function startFileServer(token) {
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, `http://${LAN}:${PORT}`);
    if (req.headers.authorization !== `Bearer ${token}`) {
      res.writeHead(401).end('bridge: bad token');
      return;
    }
    if (url.pathname === '/health') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, root: ROOT, name: os.hostname() }));
      return;
    }
    if (url.pathname === '/models') {
      // The desktop provider registry (ZCode has no remote API for it).
      try {
        const cfgPath = path.join(os.homedir(), '.zcode', 'v2', 'provider_config.json');
        const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
        const rules = cfg?.config ?? {};
        const providers = (rules.providerConfigRules?.providerRules ?? []).map((p) => ({
          providerId: p.providerId,
          providerName: p.providerName ?? p.providerId,
          modelOrder: p.config?.modelOrder ?? [],
          personalModelIds: p.config?.personalModelIds ?? [],
        }));
        const nameById = new Map(providers.map((p) => [p.providerId, p.providerName]));
        // A model is offered unless a rule explicitly disables it.
        const enabledById = new Map(
          (rules.modelConfigRules?.providerModelRules ?? []).map((m) => [
            `${m.providerId}/${m.modelId}`,
            m?.config?.enabled !== false,
          ]),
        );
        const models = [];
        const seen = new Set();
        for (const p of providers) {
          const ids = [...p.personalModelIds, ...p.modelOrder];
          for (const modelId of ids) {
            const key = `${p.providerId}/${modelId}`;
            if (!modelId || seen.has(key) || enabledById.get(key) === false) continue;
            seen.add(key);
            models.push({
              providerId: p.providerId,
              providerName: nameById.get(p.providerId) ?? p.providerId,
              modelId,
              enabled: true,
            });
          }
        }
        for (const m of rules.modelConfigRules?.manualProviderModelRules ?? []) {
          if (!m?.modelId) continue;
          const key = `${m.providerId}/${m.modelId}`;
          if (seen.has(key)) continue;
          seen.add(key);
          models.push({
            providerId: m.providerId,
            providerName: nameById.get(m.providerId) ?? m.providerId,
            modelId: m.modelId,
            enabled: true,
          });
        }
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ providers, models }));
      } catch (e) {
        res.writeHead(500).end(`models failed: ${e.message}`);
      }
      return;
    }
    if (url.pathname === '/fs/list') {
      const target = safePath(url.searchParams.get('path') ?? '');
      if (!target) {
        res.writeHead(403).end('outside root');
        return;
      }
      try {
        const entries = fs
          .readdirSync(target, { withFileTypes: true })
          .filter((e) => !e.name.startsWith('.'))
          .map((e) => {
            const full = path.join(target, e.name);
            let size = 0;
            try {
              if (e.isFile()) size = fs.statSync(full).size;
            } catch {}
            return {
              name: e.name,
              path: full,
              dir: e.isDirectory(),
              size,
            };
          })
          .sort((a, b) => (a.dir === b.dir ? a.name.localeCompare(b.name) : a.dir ? -1 : 1))
          .slice(0, 500);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ path: target, root: ROOT, entries }));
      } catch (e) {
        res.writeHead(400).end(`list failed: ${e.message}`);
      }
      return;
    }
    if (url.pathname === '/fs/read') {
      const target = safePath(url.searchParams.get('path') ?? '');
      if (!target) {
        res.writeHead(403).end('outside root');
        return;
      }
      try {
        const stat = fs.statSync(target);
        if (!stat.isFile()) {
          res.writeHead(400).end('not a file');
          return;
        }
        if (stat.size > 8 * 1024 * 1024) {
          res.writeHead(413).end('file too large (8 MB)');
          return;
        }
        const ext = path.extname(target).toLowerCase();
        const types = {
          '.png': 'image/png',
          '.jpg': 'image/jpeg',
          '.jpeg': 'image/jpeg',
          '.gif': 'image/gif',
          '.webp': 'image/webp',
          '.svg': 'image/svg+xml',
          '.pdf': 'application/pdf',
          '.json': 'application/json',
        };
        res.writeHead(200, {
          'Content-Type': types[ext] ?? 'application/octet-stream',
          'Content-Length': stat.size,
        });
        fs.createReadStream(target).pipe(res);
      } catch (e) {
        res.writeHead(404).end(`read failed: ${e.message}`);
      }
      return;
    }
    res.writeHead(404).end('bridge: unknown path');
  });
  const announce = () => {
    // Machine-readable line consumed by the phone's one-tap setup (it reads
    // the terminal output over the already-paired ZCode relay).
    const urls = LAN_IPS.map((ip) => `http://${ip}:${PORT}`);
    console.log(
      `BRIDGE_READY ${JSON.stringify({
        url: urls[0] ?? `http://127.0.0.1:${PORT}`,
        urls,
        token,
      })}`,
    );
  };
  server.listen(PORT, '0.0.0.0', () => {
    console.log('');
    console.log('  ZCode Fold — файловый мост (только чтение)');
    console.log('  ─────────────────────────────────────────────');
    console.log(`  URL   : http://${LAN}:${PORT}`);
    console.log(`  Токен : ${token}`);
    console.log(`  Корень: ${ROOT}`);
    console.log('  В приложении: Настройки → «Файлы ПК», укажи URL и токен.');
    console.log('  ─────────────────────────────────────────────');
    console.log('  CTRL+C — остановить.');
    announce();
  });
  server.on('error', (e) => {
    if (e && e.code === 'EADDRINUSE') {
      // Another bridge is already serving (same token file): report its
      // address so the phone can simply reuse it.
      announce();
      setTimeout(() => process.exit(0), 200);
      return;
    }
    throw e;
  });
  return server;
}

// ---------------------------------------------------------------------------
// Mode 1: one-shot credentials handover
// ---------------------------------------------------------------------------

function startCredentialBridge() {
  const creds = JSON.parse(
    fs.readFileSync(path.join(os.homedir(), '.zcode', 'v2', 'credentials.json'), 'utf8'),
  );
  let provider = 'zai';
  try {
    provider = dec(creds['oauth:active_provider']) || 'zai';
  } catch {}
  const jwt = dec(creds['zcodejwttoken']);
  const access = (() => {
    try {
      return dec(creds['oauth:zai:access_token']);
    } catch {
      return '';
    }
  })();
  const userInfo = (() => {
    try {
      return dec(creds['oauth:zai:user_info']);
    } catch {
      return '';
    }
  })();

  const pin = crypto.randomBytes(5).toString('hex');
  const fsTokenFile = path.resolve('bridge-fs.token');
  let fsToken = '';
  if (fs.existsSync(fsTokenFile)) {
    fsToken = fs.readFileSync(fsTokenFile, 'utf8').trim();
  }
  const payload = JSON.stringify({
    v: 1,
    provider,
    jwt,
    access,
    user: userInfo,
    bridgeUrl: `http://${LAN}:${PORT}`,
    fsToken,
  });

  const server = http.createServer((req, res) => {
    if (req.url !== `/${pin}`) {
      res.writeHead(404).end('bridge: bad pin');
      return;
    }
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(payload);
    console.log('✅ токен отдан и мост закрыт');
    setTimeout(() => process.exit(0), 500);
  });

  server.listen(PORT, '0.0.0.0', async () => {
    const url = `http://${LAN}:${PORT}/${pin}`;
    const qrPng = path.resolve('bridge-qr.png');
    await QRCode.toFile(qrPng, url, { margin: 2, scale: 8 });
    console.log('');
    console.log('  ZCode Fold — мост: креды аккаунта с этого ПК на телефон');
    console.log('  ─────────────────────────────────────────────');
    console.log(`  URL     : ${url}`);
    console.log(`  QR      : ${qrPng}`);
    console.log('  Действие: отсканируй QR приложением (кнопка «QR») →');
    console.log('            приложение заберёт токен и подключится.');
    console.log('  Срок    : одноразовый PIN; после передачи мост закрывается.');
    console.log('  ─────────────────────────────────────────────');
    console.log('  CTRL+C — отменить мост.');
  });
}

if (serveMode) {
  const tokenFile = path.resolve('bridge-fs.token');
  let token = fs.existsSync(tokenFile)
    ? fs.readFileSync(tokenFile, 'utf8').trim()
    : '';
  if (!token) {
    token = crypto.randomBytes(16).toString('base64url');
    fs.writeFileSync(tokenFile, token, 'utf8');
  }
  startFileServer(token);
} else {
  startCredentialBridge();
}
