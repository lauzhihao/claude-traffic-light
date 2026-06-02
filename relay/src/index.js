// Claude 红绿灯 APNs 中继
// 三个角色：
//   iOS App      - POST /register        注册 Live Activity push token
//   Mac Agent    - POST /update          推送状态 + 配额 + 待批准操作
//   iOS App      - POST /command         发送遥控命令（批准/拒绝）
//   Mac Agent    - GET  /commands        轮询命令队列
//   任意         - GET  /health          诊断

const VALID_STATES = ['R', 'Y', 'G'];

let cachedJwt = null;
let cachedJwtExp = 0;
let cachedKey = null;

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    try {
      if (req.method === 'POST' && url.pathname === '/register') return register(req, env);
      if (req.method === 'POST' && url.pathname === '/update') return update(req, env);
      if (req.method === 'POST' && url.pathname === '/command') return commandPost(req, env);
      if (req.method === 'GET' && url.pathname === '/commands') return commandsGet(url, env);
      if (req.method === 'GET' && url.pathname === '/health') return health(env);
      return new Response('Not found', { status: 404 });
    } catch (e) {
      return json({ error: e.message }, 500);
    }
  },
};

async function register(req, env) {
  const body = await req.json();
  if (body.secret !== env.REGISTER_SECRET) return json({ error: 'bad secret' }, 401);
  if (!body.token) return json({ error: 'token required' }, 400);
  await env.STORE.put(`token:${body.token}`, JSON.stringify({ registeredAt: Date.now() }));
  return json({ ok: true });
}

async function update(req, env) {
  const body = await req.json();
  if (body.secret !== env.UPDATE_SECRET) return json({ error: 'bad secret' }, 401);
  if (!VALID_STATES.includes(body.state)) return json({ error: 'state must be R/Y/G' }, 400);

  const contentState = {
    state: body.state,
    updatedAt: Math.floor(Date.now() / 1000),
  };
  if (body.quota) contentState.quota = body.quota;
  if (body.pending) contentState.pending = body.pending;

  await env.STORE.put('latest_state', JSON.stringify(contentState));

  const list = await env.STORE.list({ prefix: 'token:' });
  if (list.keys.length === 0) {
    return json({ ok: true, pushed: 0, note: 'no tokens registered' });
  }

  const jwt = await getJwt(env);
  const topic = `${env.APNS_BUNDLE_ID}.push-type.liveactivity`;
  const payload = JSON.stringify({
    aps: {
      timestamp: contentState.updatedAt,
      event: 'update',
      'content-state': contentState,
    },
  });

  const host = (env.APNS_ENV || 'development') === 'production'
    ? 'api.push.apple.com'
    : 'api.development.push.apple.com';

  const results = await Promise.all(
    list.keys.map(async ({ name: key }) => {
      const token = key.slice('token:'.length);
      const resp = await fetch(`https://${host}/3/device/${token}`, {
        method: 'POST',
        headers: {
          authorization: `bearer ${jwt}`,
          'apns-topic': topic,
          'apns-push-type': 'liveactivity',
          'apns-priority': '10',
          'content-type': 'application/json',
        },
        body: payload,
      });
      if (resp.status === 410 || resp.status === 400) {
        await env.STORE.delete(key);
      }
      return { token: token.slice(0, 8) + '…', status: resp.status };
    })
  );

  return json({ ok: true, pushed: results.length, results });
}

async function commandPost(req, env) {
  const body = await req.json();
  if (body.secret !== env.COMMAND_SECRET) return json({ error: 'bad secret' }, 401);
  if (!body.action || !body.id) return json({ error: 'action and id required' }, 400);

  const existing = await env.STORE.get('commands');
  const queue = existing ? JSON.parse(existing) : [];
  queue.push({ id: body.id, action: body.action, ts: Date.now() });
  await env.STORE.put('commands', JSON.stringify(queue.slice(-10)));

  return json({ ok: true, queued: queue.length });
}

async function commandsGet(url, env) {
  if (url.searchParams.get('secret') !== env.COMMAND_SECRET) {
    return json({ error: 'bad secret' }, 401);
  }
  const existing = await env.STORE.get('commands');
  const queue = existing ? JSON.parse(existing) : [];
  if (queue.length > 0) await env.STORE.delete('commands');
  return json({ commands: queue });
}

async function health(env) {
  const list = await env.STORE.list({ prefix: 'token:' });
  const latest = await env.STORE.get('latest_state');
  return json({
    ok: true,
    tokens: list.keys.length,
    env: env.APNS_ENV || 'development',
    bundle: env.APNS_BUNDLE_ID,
    latest: latest ? JSON.parse(latest) : null,
  });
}

async function getJwt(env) {
  const now = Math.floor(Date.now() / 1000);
  if (cachedJwt && cachedJwtExp - now > 600) return cachedJwt;
  if (!cachedKey) cachedKey = await importP8(env.APNS_KEY_P8);

  const header = b64url(JSON.stringify({ alg: 'ES256', kid: env.APNS_KEY_ID, typ: 'JWT' }));
  const payload = b64url(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: now }));
  const signingInput = `${header}.${payload}`;
  const sig = await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    cachedKey,
    new TextEncoder().encode(signingInput)
  );
  cachedJwt = `${signingInput}.${b64urlBytes(new Uint8Array(sig))}`;
  cachedJwtExp = now + 3000;
  return cachedJwt;
}

async function importP8(pem) {
  const body = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, '')
    .replace(/-----END PRIVATE KEY-----/, '')
    .replace(/\s+/g, '');
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey(
    'pkcs8',
    der,
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign']
  );
}

function b64url(s) {
  return btoa(s).replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}

function b64urlBytes(bytes) {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}
