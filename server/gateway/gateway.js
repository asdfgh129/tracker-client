/*
 * TrackerOne 推送网关（BFF-lite，ADR-013）· 参考实现
 *
 * 零依赖 Node.js（>= 18）。职责边界见 docs/08 ADR-013：
 *   做：接收 Traccar webhook（HMAC 鉴权）、event.id 幂等、限流（超限合并
 *       延后补发）、别名签发与归属校验、中英双语模板渲染、下发极光 REST
 *       （失败指数退避重试 + 死信 + /v1/flush 手动补发）。
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
 * H-4：下行远程指令带 HMAC 签名（userId|command|issuedAt），但签名密钥
 *      是**注册时网关为每个别名生成的独立 commandSecret**（HTTPS + 会话
 *      Token 鉴权后下发，客户端存 Secure Storage）。不再使用打进 App 的
 *      全局共享密钥——反编译客户端拿不到任何可用的指令签名密钥。
 *
 * 环境变量（**全部必填项缺失即拒绝启动**）：
 *   TRACCAR_WEBHOOK_SECRET  与 traccar.xml notificator.webhook.secret 一致
 *   GATEWAY_ADMIN_TOKEN     内部运维令牌（仅用于健康检查等本地操作）
 *   TRACCAR_API_BASE        用于反查会话身份，如 https://track.example.com
 *   JPUSH_APP_KEY           极光 AppKey
 *   JPUSH_MASTER_SECRET     极光 Master Secret（只放服务端）
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

// ---- 存储（单实例内存实现；多实例换 Redis）----
// alias -> { userId, serverId, commandSecret, platform, vendor, deviceModel,
//            appVersion, registeredAt, lastSeenAt }
// commandSecret：注册时为每个别名生成的独立指令签名密钥（H-4）。
const aliases = new Map();
// eventId -> 时间戳（幂等）
const seenEvents = new Map();
// alias -> [时间戳]（限流窗口）
const rateWindow = new Map();
// userId -> salt（别名盐值）
const salts = new Map();
// alias -> [payload]（限流合并队列：超限的投递延后补发，不直接丢弃）
const pendingPushes = new Map();
// deadId -> { alias, payload, locale, attempts, lastError, failedAt }（死信）
const deadLetters = new Map();

const MAX_ALIASES = 200_000;
const MAX_SEEN_EVENTS = 500_000;
const EVENT_TTL_MS = 24 * 60 * 60 * 1000;
const ALIAS_IDLE_TTL_MS = 90 * 24 * 60 * 60 * 1000;
const SALT_TTL_MS = 180 * 24 * 60 * 60 * 1000;
const RATE_LIMIT_PER_MINUTE = 60;
const MAX_BODY_BYTES = 256 * 1024;

// ---- 韧性（自 opencode 线 Go 网关移植）----
// 极光投递失败：指数退避后台重试（不阻塞 webhook 响应），仍失败进死信，
// 由 `POST /v1/flush`（管理令牌）手动补发。4xx（鉴权/参数）不重试直接死信。
const PUSH_MAX_ATTEMPTS = 3;
const PUSH_RETRY_BASE_MS = 2_000;
const PUSH_RETRY_MAX_MS = 30_000;
const MAX_PENDING_PER_ALIAS = 20;
const MAX_DEAD_LETTERS = 10_000;
const PENDING_FLUSH_DELAY_MS = 60_000; // 限流窗口长度

function log(...args) {
  console.log(new Date().toISOString(), ...args);
}

// ---- M-2：定期清扫 + 容量上限 ----
const DEAD_LETTER_TTL_MS = 7 * 24 * 60 * 60 * 1000;

function sweep() {
  const now = Date.now();
  for (const [id, t] of seenEvents) {
    if (now - t > EVENT_TTL_MS) seenEvents.delete(id);
  }
  for (const [id, entry] of deadLetters) {
    if (now - entry.failedAt > DEAD_LETTER_TTL_MS) deadLetters.delete(id);
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

// ---- 模板渲染（docs/09 §3.7；Traccar webhook 头 X-Locale 决定语言）----
function renderMessage(payload, locale = 'zh') {
  const message = payload.message || {};
  if (message.title || message.body) {
    return { title: message.title || 'TrackerOne', body: message.body || '' };
  }
  const type = (payload.event && payload.event.type) || 'event';
  const deviceName = payload.deviceName || '';
  const templates =
    locale === 'en'
      ? {
          geofenceEnter: { title: 'Geofence entered', body: `${deviceName} entered a geofence` },
          geofenceExit: { title: 'Geofence exited', body: `${deviceName} left a geofence` },
          deviceOffline: { title: 'Device offline', body: `${deviceName} went offline` },
          deviceOnline: { title: 'Device online', body: `${deviceName} is back online` },
          alarm: { title: 'Alarm', body: `${deviceName} triggered an alarm` },
          overspeed: { title: 'Overspeed', body: `${deviceName} is speeding` },
          deviceOverspeed: { title: 'Overspeed', body: `${deviceName} is speeding` },
          sos: { title: 'SOS', body: `${deviceName} sent an SOS` },
        }
      : {
          geofenceEnter: { title: '进入围栏', body: `${deviceName} 进入围栏区域` },
          geofenceExit: { title: '离开围栏', body: `${deviceName} 离开围栏区域` },
          deviceOffline: { title: '设备离线', body: `${deviceName} 已离线` },
          deviceOnline: { title: '设备上线', body: `${deviceName} 已上线` },
          alarm: { title: '告警', body: `${deviceName} 触发告警` },
          overspeed: { title: '超速', body: `${deviceName} 超速行驶` },
          deviceOverspeed: { title: '超速', body: `${deviceName} 超速行驶` },
          sos: { title: 'SOS 求助', body: `${deviceName} 发送 SOS 求助` },
        };
  const template =
    templates[type] || { title: 'TrackerOne', body: `${deviceName} ${type}` };
  return { title: template.title, body: template.body };
}

/** H-4：为下行远程指令生成签名（与 App 侧同构；密钥为别名独立密钥）。 */
function signCommand(userId, command, issuedAt, commandSecret) {
  if (!commandSecret) return null;
  return crypto
    .createHmac('sha256', commandSecret)
    .update(`${userId}|${command}|${issuedAt}`)
    .digest('base64url');
}

// ---- 极光投递（韧性：首试内联 + 指数退避后台重试 + 死信）----

function deadLetter(alias, payload, locale, attempts, lastError) {
  const id = `${alias}:${payload.event && payload.event.id}:${Date.now()}`;
  deadLetters.set(id, { alias, payload, locale, attempts, lastError, failedAt: Date.now() });
  evictIfNeeded(deadLetters, MAX_DEAD_LETTERS);
  log('dead letter', `alias=${alias} attempts=${attempts} error=${lastError}`);
}

/** 用别名当前信息构建极光请求体；别名已被删除时返回 null。 */
function buildNotification(alias, payload, locale) {
  const info = aliases.get(alias);
  if (!info) {
    log('alias not registered; push skipped (alias=' + alias + ')');
    return null;
  }
  info.lastSeenAt = Date.now();

  const { title, body } = renderMessage(payload, locale);
  const extras = {
    eventId: String((payload.event && payload.event.id) || ''),
    deviceId: String(payload.deviceId || ''),
    type: (payload.event && payload.event.type) || '',
  };

  // 若上游要求下发远程指令，附带 HMAC 签名（H-4，别名独立密钥）。
  const command = payload.command;
  if (command) {
    const issuedAt = Date.now();
    const sig = signCommand(info.userId, command, issuedAt, info.commandSecret);
    if (!sig) {
      log('command dropped: alias 无 commandSecret（旧注册记录）');
      return null;
    }
    extras.command = String(command);
    extras.userId = String(info.userId);
    extras.issuedAt = String(issuedAt);
    extras.sig = sig;
  }

  return {
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
}

async function jpushPush(notification) {
  const auth = Buffer.from(`${JPUSH_APP_KEY}:${JPUSH_MASTER_SECRET}`).toString('base64');
  const response = await fetch('https://api.jpush.cn/v3/push', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Basic ${auth}`,
    },
    body: JSON.stringify(notification),
  });
  const text = await response.text();
  return { status: response.status, ok: response.ok, text };
}

/**
 * 单次投递尝试（第 [attempt] 次，从 1 起）。
 *
 * 成功返回 true；4xx（鉴权/参数类，重试无意义）直接死信；
 * 5xx/网络错误在后台按指数退避重试（不阻塞 webhook 响应），
 * 超过 PUSH_MAX_ATTEMPTS 仍失败进死信，等待 /v1/flush 手动补发。
 */
async function deliverOnce(alias, payload, locale, attempt) {
  if (!JPUSH_APP_KEY || !JPUSH_MASTER_SECRET) {
    log('jpush not configured; event dropped (alias=' + alias + ')');
    return false;
  }
  const notification = buildNotification(alias, payload, locale);
  if (!notification) return false;

  let lastError = 'unknown';
  try {
    const { status, ok, text } = await jpushPush(notification);
    if (ok) {
      log('jpush sent', 'msg_id=' + (JSON.parse(text).msg_id || '-'));
      return true;
    }
    log('jpush failed', status, text.slice(0, 200));
    if (status >= 400 && status < 500) {
      deadLetter(alias, payload, locale, attempt, `jpush ${status}`);
      return false;
    }
    lastError = `jpush ${status}`;
  } catch (error) {
    log('jpush error', error.message);
    lastError = error.message;
  }

  if (attempt < PUSH_MAX_ATTEMPTS) {
    const delay = Math.min(
      PUSH_RETRY_BASE_MS * 2 ** (attempt - 1),
      PUSH_RETRY_MAX_MS,
    );
    setTimeout(() => {
      deliverOnce(alias, payload, locale, attempt + 1);
    }, delay).unref();
    log('jpush retry scheduled', `alias=${alias} attempt=${attempt + 1} in=${delay}ms`);
    return false;
  }
  deadLetter(alias, payload, locale, attempt, lastError);
  return false;
}

async function pushViaJPush(alias, payload, locale = 'zh') {
  return deliverOnce(alias, payload, locale, 1);
}

// ---- 限流合并（A 线语义：超限延后补发，而不是丢弃）----

function enqueuePending(alias, payload, locale) {
  const queue = pendingPushes.get(alias) || [];
  queue.push({ payload, locale });
  // 合并：只保留最新的 MAX_PENDING_PER_ALIAS 条（FIFO 淘汰旧事件）。
  while (queue.length > MAX_PENDING_PER_ALIAS) queue.shift();
  pendingPushes.set(alias, queue);
  setTimeout(() => flushPending(alias), PENDING_FLUSH_DELAY_MS).unref();
}

function flushPending(alias) {
  const queue = pendingPushes.get(alias);
  if (!queue || queue.length === 0) return;
  pendingPushes.set(alias, []);
  for (const item of queue) {
    if (rateLimited(alias)) {
      enqueuePending(alias, item.payload, item.locale);
      continue;
    }
    deliverOnce(alias, item.payload, item.locale, 1);
  }
}

// ---- 死信补发（POST /v1/flush，管理令牌）----

/** 单轮直接补发（不走重试机制，避免重复入死信）。返回成功条数。 */
async function flushDeadLetters() {
  let flushed = 0;
  for (const [id, entry] of [...deadLetters]) {
    try {
      const notification = buildNotification(entry.alias, entry.payload, entry.locale);
      if (!notification) {
        deadLetters.delete(id); // 别名已删除，条目失效。
        continue;
      }
      const { ok } = await jpushPush(notification);
      if (ok) {
        deadLetters.delete(id);
        flushed++;
        continue;
      }
    } catch (error) {
      log('flush error', error.message);
    }
    entry.attempts++;
    if (entry.attempts >= PUSH_MAX_ATTEMPTS * 3) {
      deadLetters.delete(id); // 多轮补发仍失败，放弃避免无限堆积。
    }
  }
  return flushed;
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
      const locale = (req.headers['x-locale'] || 'zh').toString();
      for (const alias of targets) {
        if (rateLimited(alias)) {
          // 超限合并延后补发（60s 后按窗口容量再投，不直接丢弃）。
          log('rate limited, merged for later (alias=' + alias + ')');
          enqueuePending(alias, payload, locale);
          continue;
        }
        delivered = (await pushViaJPush(alias, payload, locale)) || delivered;
      }
      // 投递失败已进入重试/死信流程，Traccar 不自动重试（README §2.1）。
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

      // H-4：为别名签发独立的指令签名密钥；重复注册保持稳定，
      // 让客户端重装后仍能取回同一密钥。
      const existing = aliases.get(alias);
      const commandSecret =
        (existing && existing.commandSecret) ||
        crypto.randomBytes(32).toString('base64url');

      aliases.set(alias, {
        userId,
        serverId: Number(match[2]),
        commandSecret,
        platform: typeof body.platform === 'string' ? body.platform : 'unknown',
        vendor: typeof body.vendor === 'string' ? body.vendor : null,
        deviceModel: typeof body.deviceModel === 'string' ? body.deviceModel : null,
        appVersion: typeof body.appVersion === 'string' ? body.appVersion : null,
        registeredAt: Date.now(),
        lastSeenAt: Date.now(),
      });
      evictIfNeeded(aliases, MAX_ALIASES);
      log('alias registered', `u${userId}@…`); // 不打印完整别名（含盐值）
      // commandSecret 经 HTTPS + 会话鉴权下发，客户端存 Secure Storage。
      return send(res, 200, { ok: true, commandSecret });
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

    // ===== 运维：死信查看（C-1：必须带管理令牌）=====
    if (route === 'GET /v1/dead') {
      if (!ADMIN_TOKEN || !timingSafeEqualStr(bearer(req), ADMIN_TOKEN)) {
        return send(res, 403, { error: 'admin token required' });
      }
      const entries = [...deadLetters.entries()].map(([id, entry]) => ({
        id,
        alias: entry.alias.replace(/\.[A-Za-z0-9_-]+$/, '.…'), // 不泄露盐值
        eventId: String((entry.payload.event && entry.payload.event.id) || ''),
        attempts: entry.attempts,
        lastError: entry.lastError,
        failedAt: new Date(entry.failedAt).toISOString(),
      }));
      return send(res, 200, { ok: true, count: entries.length, entries });
    }

    // ===== 运维：死信补发（C-1：必须带管理令牌）=====
    if (route === 'POST /v1/flush') {
      if (!ADMIN_TOKEN || !timingSafeEqualStr(bearer(req), ADMIN_TOKEN)) {
        return send(res, 403, { error: 'admin token required' });
      }
      const flushed = await flushDeadLetters();
      return send(res, 200, { ok: true, flushed });
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
  log('command signing  per-alias secret (issued at registration)');
  log(`push resilience  retry=${PUSH_MAX_ATTEMPTS} deadletter=on ratemerge=on`);
  log(`traccar api      ${TRACCAR_API_BASE || 'not configured'}`);
});
