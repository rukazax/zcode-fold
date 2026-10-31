const token = process.env.TOKEN;
const base = 'ws://127.0.0.1:8377/acp';

async function main() {
  const list = await fetch('http://127.0.0.1:8377/api/instances?probe=1', {
    headers: { Authorization: `Bearer ${token}` },
  }).then((r) => r.json());
  if (!list.length) throw new Error('no instances');
  const inst = list[0];
  console.log('instance', inst.id, inst.workspace);

  const ws = new WebSocket(`${base}?instance=${inst.id}&token=${token}`);
  let nextId = 1;
  const pending = new Map();
  const send = (method, params = {}) =>
    new Promise((resolve, reject) => {
      const id = nextId++;
      pending.set(id, { resolve, reject });
      ws.send(JSON.stringify({ jsonrpc: '2.0', id, method, params }));
    });

  ws.onmessage = (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.method) {
      if (msg.id !== undefined) {
        console.log('SERVER REQUEST', msg.method, JSON.stringify(msg.params).slice(0, 400));
        ws.send(
          JSON.stringify({
            jsonrpc: '2.0',
            id: msg.id,
            result: { outcome: { outcome: 'cancelled' } },
          }),
        );
        return;
      }
      if (msg.method === 'session/update') {
        const u = msg.params.update || {};
        const text =
          u.content && (u.content.text ?? (Array.isArray(u.content) ? u.content.map((c) => c.text || '').join('') : ''));
        console.log('UPDATE', u.sessionUpdate, (text || u.title || u.status || '').toString().slice(0, 120));
      } else {
        console.log('NOTIFY', msg.method, JSON.stringify(msg.params).slice(0, 200));
      }
      return;
    }
    const p = pending.get(msg.id);
    if (p) {
      pending.delete(msg.id);
      msg.error
        ? p.reject(new Error(JSON.stringify(msg.error)))
        : p.resolve(msg.result);
    }
  };

  await new Promise((res, rej) => {
    ws.onopen = res;
    ws.onerror = () => rej(new Error('ws error'));
  });
  const init = await send('initialize', { protocolVersion: 1, clientCapabilities: {} });
  console.log('INIT', JSON.stringify(init).slice(0, 300));

  const newsess = await send('session/new', { cwd: inst.workspace, mcpServers: [] });
  console.log('NEW', JSON.stringify(newsess).slice(0, 300));
  const sid = newsess.sessionId;

  const prompt = await send('session/prompt', {
    sessionId: sid,
    prompt: [{ type: 'text', text: 'Ответь одним словом: привет' }],
  });
  console.log('PROMPT DONE', JSON.stringify(prompt).slice(0, 400));
  ws.close();
}

main().catch((e) => {
  console.error('FAIL', e.message);
  process.exit(1);
});
