// ZCode Fold — desktop credential bridge.
//
// Serves the desktop's own Z.ai JWT to a paired phone over the local network
// with a one-time PIN. The phone then mints its own terminal tokens, and
// everything relay-side works with the same account as on the computer —
// without any login inside the phone.
//
// Usage:  node bridge.mjs
// Prints: http://<lan-ip>:8939/<pin>  plus a QR PNG (bridge.png)
// The PIN is randomly generated per run; the server exits after one fetch
// (or Ctrl+C). Same trust boundary as the ZCode QR: scan == hand over the
// desktop account to that phone on this LAN only.

import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import QRCode from 'qrcode';

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

const creds = JSON.parse(
  fs.readFileSync(path.join(os.homedir(), '.zcode', 'v2', 'credentials.json'), 'utf8'),
);
let provider = 'zai';
try { provider = dec(creds['oauth:active_provider']) || 'zai'; } catch {}
const jwt = dec(creds['zcodejwttoken']);
const access = (() => {
  try { return dec(creds['oauth:zai:access_token']); } catch { return ''; }
})();
const userInfo = (() => {
  try { return dec(creds['oauth:zai:user_info']); } catch { return ''; }
})();

const pin = crypto.randomBytes(5).toString('hex');
const payload = JSON.stringify({ v: 1, provider, jwt, access, user: userInfo });

function lanIp() {
  const ifaces = Object.values(os.networkInterfaces()).flat();
  const v4 = ifaces.find(
    (i) => i?.family === 'IPv4' && !i.internal && net.isIPv4(i.address),
  );
  return v4?.address ?? '127.0.0.1';
}

const server = http.createServer((req, res) => {
  if (req.url !== `/${pin}`) {
    res.writeHead(404).end('bridge: bad pin');
    return;
  }
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(payload);
  console.log(`✅ токен отдан и мост закрыт`);
  setTimeout(() => process.exit(0), 500);
});

server.listen(8939, '0.0.0.0', async () => {
  const url = `http://${lanIp()}:8939/${pin}`;
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
