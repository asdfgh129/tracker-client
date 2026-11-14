/*
 * TrackerOne 推送网关（BFF-lite，ADR-013）· 参考实现
 *
 * 零依赖 Node.js（>= 18）。职责边界见 docs/08 ADR-013：
 *   做：接收 Traccar webhook（HMAC 鉴权）、event.id 幂等、限流、
 *       别名签发与归属校验、模板渲染、下发极光 REST。
 *   不做：不代理 REST/WebSocket、不存业务数据、不做账号体系。
 *
 * ===== 安全设计（对应安全审计整改）=====
 * C-1：**无默认管理令牌**。GATEWAY_ADMIN_TOKEN 未配置时拒绝启动，
 *      且所有令牌比较用常量时间比较。
 * H-2：别名归属校验。`POST /v1/alias-salt` 需要 App 提供 Traccar 会话
 *      Token，网关反查 userId 后签发随机盐；别名形如
 *      `u{userId}@{serverId}.{salt}`，客户端无法自行编造他人别名。
 * C-2：盐值随机 128bit，别名/主题不可枚举（避免他人订阅事件推送）。
 * M-2：请求体上限 → 413；JSON/URL 解析失败 → 400；别名表与限流表
 *      有容量上限与 TTL，避免内存型 DoS。
 * H-4：下行远程指令带 HMAC 签名（userId|command|issuedAt），
 *      App 侧验签（COMMAND_HMAC_KEY）。
 *
 * 环境变量（**全部必填项缺失即拒绝启动**）：
 *   TRACCAR_WEBHOOK_SECRET  与 traccar.xml notificator.webhook.secret 一致
 *   GATEWAY_ADMIN_TOKEN     内部运维令牌（仅用于健康检查等本地操作）
 *   TRACCAR_API_BASE        用于反查会话身份，如 https://track.example.com
 *   JPUSH_APP_KEY           极光 AppKey
 *   JPUSH_MASTER_SECRET     极光 Master Secret（只放服务端）
 *   COMMAND_HMAC_KEY        远程指令签名密钥（与 App dart-define 一致）
 *   GATEWAY_PORT            默认 8080
 *
 * 运行：
 *   node gateway.js
 *
 * 生产注意：内存 Map 只适用于单实例；多实例请换 Redis（README §3）。
 */
'use strict';

const http = require('node:http');
const crypto = require('node:crypto');

// ---- 配置与启动校验（C-1：缺失即 fail-closed）----
const PORT = Number(process.env.GATEWAY_PORT || 8080);
const WEBHOOK_SECRET = process.env.TRACCAR_WEBHOOK_SECRET || '';
const ADMIN_TOKEN = process.env.GATEWAY_ADMIN_TOKEN || '';
const JPUSH_APP_KEY = process.env.JPUSH_APP_KEY || '';
const JPUSH_MASTER_SECRET = process.env.JPUSH_MASTER_SECRET || '';
const COMMAND_HMAC_KEY = process.env.COMMAND_HMAC_KEY || '';
const TRACCAR_API_BASE = (process.env.TRACCAR_API_BASE || '').replace(/\/+$/, '');

// 允许本地联调用弱配置，但必须显式声明；生产（NODE_ENV=production）禁止。
const IS_PROD = process.env.NODE_ENV === 'production';
const ALLOW_INSECURE_DEV = process.env.GATEWAY_ALLOW_INSECURE_DEV === '1';

function fatal(message) {
  console.error('[fatal]', message);
  process.exit(1);
}

if (!WEBHOOK_SECRET) fatal('缺少 TRACCAR_WEBHOOK_SECRET（Traccar → 网关的 HMAC 密钥）');
if (!ADMIN_TOKEN) fatal('缺少 GATEWAY_ADMIN_TOKEN（禁止使用默认令牌）');
if (!TRACCAR_API_BASE || !/^https:\/\//.test(TRACCAR_API_BASE)) {
  if (!ALLOW_INSECURE_DEV) {
    fatal('TRACCAR_API_BASE 必须是 https:// 地址（本地联调可设 GATEWAY_ALLOW_INSECURE_DEV=1）');
  }
}
if (IS_PROD && ADMIN_TOKEN.length < 32) {
  fatal('GATEWAY_ADMIN_TOKEN 长度不足 32（生产要求强随机）');
}
if (!COMMAND_HMAC_KEY && !ALLOW_INSECURE_DEV) {
  fatal('缺少 COMMAND_HMAC_KEY（下行远程指令签名密钥）');
}

// ---- 存储（单实例内存实现；多实例换 Redis）----
// alias -> { userId, serverId, platform, vendor, appVersion, registeredAt, lastSeenAt }
const aliases = new Map();
// eventId -> 时间戳（幂等）
const seenEvents = new Map();
// alias -> [时间戳]（限流窗口）
const rateWindow = new Map();
// userId -> salt（别名盐值）
const salts = new Map();

const MAX_ALIASES = 200_000;
const MAX_SEEN_EVENTS = 500_000;
const EVENT_TTL_MS = 24 * 60 * 60 * 1000;
const ALIAS_IDLE_TTL_MS = 90 * 24 * 60 * 60 * 1000;
const SALT_TTL_MS = 180 * 24 * 60 * 60 * 1000;
const RATE_LIMIT_PER_MINUTE = 60;
const MAX_BODY_BYTES = 256 * 1024;

function log(...args) {
  console.log(new Date().toISOString(), ...args);
}

// ---- M-2：定期清扫 + 容量上限 ----
function sweep() {
  const now = Date.now();
  for (const [id, t] of seenEvents) {
    if (now - t > EVENT_TTL_MS) seenEvents.delete(id);
  }
  for (const [alias, info] of aliases) {
    // 修正：以投递时间（lastSeenAt）判断活跃度，而非注册时间。
    if (now - info.lastSeenAt > ALIAS_IDLE_TTL_MS) aliases.delete(alias);
  }
  for (const [userId, entry] of salts) {
    if (now - entry.issuedAt > SALT_TTL_MS) salts.delete(userId);
  }
  // 限流窗口清理空数组，避免键无限驻留。
  for (const [alias, window] of rateWindow) {
    const alive = window.filter((t) => now - t < 60_000);
    if (alive.length === 0) rateWindow.delete(alias);
    else rateWindow.set(alias, alive);
  }
}
setInterval(sweep, 10 * 60 * 1000).unref();

function evictIfNeeded(map, max) {
  if (map.size <= max) return;
  // 简单 FIFO 淘汰（Map 保持插入顺序），避免内存无界增长。
  const excess = map.size - max;
  let removed = 0;
  for (const key of map.keys()) {
    map.delete(key);
    if (++removed >= excess) break;
  }
  log('evicted', removed, 'entries (capacity guard)');
}

// ---- 工具 ----
function timingSafeEqualStr(a, b) {
  const bufA = Buffer.from(String(a));
  const bufB = Buffer.from(String(b));
  if (bufA.length !== bufB.length) return false;
  return crypto.timingSafeEqual(bufA, bufB);
}

function verifySignature(rawBody, header) {
  if (!WEBHOOK_SECRET) return false;
  if (!header || !header.startsWith('sha256=')) return false;
  const expected =
    'sha256=' +
    crypto.createHmac('sha256', WEBHOOK_SECRET).update(rawBody).digest('hex');
  return timingSafeEqualStr(header, expected);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        const error = new Error('body too large');
        error.code = 'BODY_TOO_LARGE';
        req.destroy();
        reject(error);
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function send(res, status, body) {
  const payload = body === undefined ? '' : JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(payload),
  });
  res.end(payload);
}

function rateLimited(alias) {
  const now = Date.now();
  const window = (rateWindow.get(alias) || []).filter((t) => now - t < 60_000);
  if (window.length >= RATE_LIMIT_PER_MINUTE) {
    rateWindow.set(alias, window);
    return true;
  }
  window.push(now);
  rateWindow.set(alias, window);
  return false;
}

function bearer(req) {
  const auth = req.headers.authorization || '';
  return auth.startsWith('Bearer ') ? auth.slice(7) : '';
}

/** H-2：用 App 携带的 Traccar 会话 Token 反查用户身份。 */
async function resolveUserId(traccarToken) {
  if (!traccarToken || !TRACCAR_API_BASE) return null;
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 5000);
    const response = await fetch(`${TRACCAR_API_BASE}/api/session`, {
      headers: { Authorization: `Bearer ${traccarToken}`, Accept: 'application/json' },
      signal: controller.signal,
    });
    clearTimeout(timer);
    if (!response.ok) return null;
    const user = await response.json();
    return typeof user.id === 'number' ? user.id : null;
  } catch (error) {
    log('session verify failed', error.message);
    return null;
  }
}

// ---- 模板渲染（docs/09 §3.7）----
function renderMessage(payload) {
  const message = payload.message || {};
  if (message.title || message.body) {
    return { title: message.title || 'TrackerOne', body: message.body || '' };
  }
  const type = (payload.event && payload.event.type) || 'event';
  const deviceName = payload.deviceName || '';
  const templates = {
    geofenceEnter: { title: '进入围栏', body: `${deviceName} 进入围栏区域` },
    geofenceExit: { title: '离开围栏', body: `${deviceName} 离开围栏区域` },
    deviceOffline: { title: '设备离线', body: `${deviceName} 已离线` },
    deviceOnline: { title: '设备上线', body: `${deviceName} 已上线` },
    alarm: { title: '告警', body: `${deviceName} 触发告警` },
    overspeed: { title: '超速', body: `${deviceName} 超速行驶` },
    sos: { title: 'SOS 求助', body: `${deviceName} 发送 SOS 求助` },
  };
  const template =
    templates[type] || { title: 'TrackerOne', body: `${deviceName} ${type}` };
  return { title: template.title, body: template.body };
}

/** H-4：为下行远程指令生成签名（与 App 侧同构）。 */
function signCommand(userId, command, issuedAt) {
  if (!COMMAND_HMAC_KEY) return null;
  return crypto
    .createHmac('sha256', COMMAND_HMAC_KEY)
    .update(`${userId}|${command}|${issuedAt}`)
    .digest('base64url');
}

async function pushViaJPush(alias, payload) {
  if (!JPUSH_APP_KEY || !JPUSH_MASTER_SECRET) {
    log('jpush not configured; event dropped (alias=' + alias + ')');
    return false;
  }
  const info = aliases.get(alias);
  if (!info) {
    log('alias not registered; push skipped (alias=' + alias + ')');
    return false;
  }
  info.lastSeenAt = Date.now();

  const { title, body } = renderMessage(payload);
  const extras = {
    eventId: String((payload.event && payload.event.id) || ''),
    deviceId: String(payload.deviceId || ''),
    type: (payload.event && payload.event.type) || '',
  };

  // 若上游要求下发远程指令，附带 HMAC 签名（H-4）。
  const command = payload.command;
  if (command) {
    const issuedAt = Date.now();
    const sig = signCommand(info.userId, command, issuedAt);
    if (!sig) {
      log('command dropped: COMMAND_HMAC_KEY 未配置');
      return false;
    }
    extras.command = String(command);
    extras.userId = String(info.userId);
    extras.issuedAt = String(issuedAt);
    extras.sig = sig;
  }

  const notification = {
    platform: ['android', 'ios'],
    audience: { alias: [alias] },
    notification: {
      android: { alert: body, title, extras },
      ios: { alert: `${title}：${body}`, sound: 'default', extras },
    },
    options: {
      time_to_live: 3600,
      apns_production: IS_PROD,
    },
  };

  const auth = Buffer.from(`${JPUSH_APP_KEY}:${JPUSH_MASTER_SECRET}`).toString('base64');
  try {
    const response = await fetch('https://api.jpush.cn/v3/push', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Basic ${auth}`,
      },
      body: JSON.stringify(notification),
    });
    const text = await response.text();
    if (!response.ok) {
      log('jpush failed', response.status, text.slice(0, 200));
      return false;
    }
    log('jpush sent', 'msg_id=' + (JSON.parse(text).msg_id || '-'));
    return true;
  } catch (error) {
    log('jpush error', error.message);
    return false;
  }
}

// ---- 路由 ----
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  const route = `${req.method} ${url.pathname}`;

  try {
    // ===== Traccar → 网关 =====
    if (route === 'POST /v1/events') {
      const raw = await readBody(req);
      if (!verifySignature(raw, req.headers['x-traccar-signature'])) {
        log('signature verify failed');
        return send(res, 401, { error: 'invalid signature' });
      }
      let payload;
      try {
        payload = JSON.parse(raw);
      } catch {
        return send(res, 400, { error: 'invalid json' });
      }

      const eventId = payload.event && payload.event.id;
      if (eventId != null && seenEvents.has(String(eventId))) {
        return send(res, 200, { ok: true, deduplicated: true });
      }
      if (eventId != null) {
        seenEvents.set(String(eventId), Date.now());
        evictIfNeeded(seenEvents, MAX_SEEN_EVENTS);
      }

      // 按 userId 计算其全部别名（一个用户可能有多台设备注册）。
      const userId = payload.userId;
      const targets = [];
      for (const [alias, info] of aliases) {
        if (info.userId === userId) targets.push(alias);
      }
      if (targets.length === 0) {
        return send(res, 200, { ok: true, delivered: false, reason: 'no-alias' });
      }

      let delivered = false;
      for (const alias of targets) {
        if (rateLimited(alias)) {
          log('rate limited (alias=' + alias + ')');
          continue;
        }
        delivered = (await pushViaJPush(alias, payload)) || delivered;
      }
      // 非 2xx 只记录日志，Traccar 不自动重试（README §2.1）。
      return send(res, 200, { ok: delivered });
    }

    // ===== App → 网关：申请别名盐（H-2/C-2）=====
    if (route === 'POST /v1/alias-salt') {
      const traccarToken = bearer(req);
      const userId = await resolveUserId(traccarToken);
      if (userId == null) {
        return send(res, 401, { error: 'invalid traccar session' });
      }
      let body;
      try {
        body = JSON.parse(await readBody(req));
      } catch (error) {
        return send(res, error.code === 'BODY_TOO_LARGE' ? 413 : 400, {
          error: 'invalid json',
        });
      }
      const serverId = Number(body.serverId || 0);
      const key = `${userId}@${serverId}`;
      const existing = salts.get(key);
      if (existing && Date.now() - existing.issuedAt < SALT_TTL_MS) {
        return send(res, 200, { salt: existing.salt, alias: `u${key}.${existing.salt}` });
      }
      // C-2：128bit 随机盐，别名不可枚举。
      const salt = crypto.randomBytes(16).toString('base64url');
      salts.set(key, { salt, issuedAt: Date.now() });
      log('salt issued for user', userId);
      return send(res, 200, { salt, alias: `u${key}.${salt}` });
    }

    // ===== App → 网关：注册别名（H-2 归属校验）=====
    if (route === 'POST /v1/aliases') {
      const traccarToken = bearer(req);
      const userId = await resolveUserId(traccarToken);
      if (userId == null) {
        return send(res, 401, { error: 'invalid traccar session' });
      }
      let body;
      try {
        body = JSON.parse(await readBody(req));
      } catch (error) {
        return send(res, error.code === 'BODY_TOO_LARGE' ? 413 : 400, {
          error: 'invalid json',
        });
      }

      const alias = typeof body.alias === 'string' ? body.alias : '';
      if (!alias || alias.length > 200) {
        return send(res, 400, { error: 'alias required' });
      }
      // H-2：别名必须形如 u{userId}@{serverId}.{salt}，且 userId 必须是
      // 当前已认证用户 —— 客户端无法注册/覆盖他人别名。
      const match = /^u(\d+)@(\d+)\.([A-Za-z0-9_-]{16,})$/.exec(alias);
      if (!match) {
        return send(res, 400, { error: 'alias format invalid' });
      }
      if (Number(match[1]) !== userId) {
        log('alias ownership mismatch', { requested: match[1], authenticated: userId });
        return send(res, 403, { error: 'alias belongs to another user' });
      }
      const saltEntry = salts.get(`${match[1]}@${match[2]}`);
      if (!saltEntry || !timingSafeEqualStr(saltEntry.salt, match[3])) {
        return send(res, 403, { error: 'salt not issued by gateway' });
      }

      aliases.set(alias, {
        userId,
        serverId: Number(match[2]),
        platform: typeof body.platform === 'string' ? body.platform : 'unknown',
        vendor: typeof body.vendor === 'string' ? body.vendor : null,
        appVersion: typeof body.appVersion === 'string' ? body.appVersion : null,
        registeredAt: Date.now(),
        lastSeenAt: Date.now(),
      });
      evictIfNeeded(aliases, MAX_ALIASES);
      log('alias registered', `u${userId}@…`); // 不打印完整别名（含盐值）
      return send(res, 200, { ok: true });
    }

    // ===== App → 网关：删除别名 =====
    if (route.startsWith('DELETE /v1/aliases/')) {
      const traccarToken = bearer(req);
      const userId = await resolveUserId(traccarToken);
      if (userId == null) {
        return send(res, 401, { error: 'invalid traccar session' });
      }
      let alias;
      try {
        alias = decodeURIComponent(url.pathname.split('/').pop() || '');
      } catch {
        return send(res, 400, { error: 'invalid alias encoding' });
      }
      const info = aliases.get(alias);
      if (!info) return send(res, 200, { ok: true });
      // H-2：只能删除自己的别名。
      if (info.userId !== userId) {
        return send(res, 403, { error: 'alias belongs to another user' });
      }
      aliases.delete(alias);
      log('alias deleted for user', userId);
      return send(res, 200, { ok: true });
    }

    if (route === 'GET /healthz') {
      // 不暴露内部计数细节（避免信息泄露），仅返回存活与规模量级。
      return send(res, 200, { ok: true, aliases: aliases.size });
    }

    return send(res, 404, { error: 'not found' });
  } catch (error) {
    if (error.code === 'BODY_TOO_LARGE') {
      return send(res, 413, { error: 'payload too large' });
    }
    log('handler error', error.message);
    return send(res, 500, { error: 'internal' });
  }
});

server.listen(PORT, () => {
  log(`push gateway listening on :${PORT}`);
  log(`hmac secret      ${WEBHOOK_SECRET ? 'configured' : 'MISSING'}`);
  log(`admin token      ${ADMIN_TOKEN ? 'configured' : 'MISSING'}`);
  log(`jpush            ${JPUSH_APP_KEY ? 'configured' : 'not configured (dry-run)'}`);
  log(`command signing  ${COMMAND_HMAC_KEY ? 'configured' : 'disabled'}`);
  log(`traccar api      ${TRACCAR_API_BASE || 'not configured'}`);
});
