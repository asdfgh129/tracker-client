# server · 中国大陆推送链路

Traccar 6.16 自带 `web` / `firebase` / `traccar` 等通知器，但**没有通用 webhook**，
而 `firebase` 在中国大陆 Android 不可用。因此需要两件东西：

```
Traccar 事件
   │  NotificatorWebhook（本目录，需打补丁）
   ▼
自建推送网关（BFF）
   │  鉴权 / 别名映射 / 去重 / 限流 / 模板 / 回执
   ▼
极光 JPush REST  ──►  小米 / 华为 / OPPO / vivo / 荣耀 厂商通道
   │
   ▼
TrackerOne App
```

## 1. 给 Traccar 打补丁

### 1.1 放置文件

```bash
cp server/traccar-plugin/src/main/java/org/traccar/notificators/NotificatorWebhook.java \
   ../traccar/src/main/java/org/traccar/notificators/
```

### 1.2 注册通知器

编辑 `src/main/java/org/traccar/notification/NotificatorManager.java`：

```java
import org.traccar.notificators.NotificatorWebhook;

private static final Map<String, Class<? extends Notificator>> NOTIFICATORS_ALL = Map.of(
        "command", NotificatorCommand.class,
        "web", NotificatorWeb.class,
        "mail", NotificatorMail.class,
        "sms", NotificatorSms.class,
        "firebase", NotificatorFirebase.class,
        "traccar", NotificatorTraccar.class,
        "telegram", NotificatorTelegram.class,
        "whatsapp", NotificatorWhatsapp.class,
        "pushover", NotificatorPushover.class,
        "webhook", NotificatorWebhook.class);   // ← 新增
```

> `Map.of` 最多支持 10 组键值对。Traccar 6.16 当前是 9 组，加入 `webhook` 后正好 10 组；
> 若之后再新增第 11 个通知器，需要改为 `Map.ofEntries(...)`。

### 1.3 配置

`conf/traccar.xml`（或环境变量）：

```xml
<entry key='notificator.types'>web,mail,webhook</entry>
<entry key='notificator.webhook.url'>https://push.example.com/v1/events</entry>
<entry key='notificator.webhook.secret'>替换为随机密钥</entry>
<entry key='notificator.webhook.timeoutSeconds'>5</entry>
<!-- 仅本地联调允许 http（生产必须 https，缺省 false） -->
<entry key='notificator.webhook.allowHttp'>false</entry>
```

### 1.4 在 Web 端启用

通知规则（Notifications）里把 `notificator` 选为 **webhook**。
默认值仍是 `web`，只推给在线 WebSocket。

### 1.5 构建

```bash
cd ../traccar
./gradlew assemble        # 或 mvn package
```

## 2. 推送网关契约

### 2.1 接收事件

`POST /v1/events`

```http
Content-Type: application/json; charset=utf-8
X-Traccar-Signature: sha256=<hmac_sha256(raw_body, secret)>
```

```json
{
  "version": 1,
  "userId": 1,
  "userEmail": "user@example.com",
  "deviceId": 42,
  "deviceName": "京A·12345",
  "uniqueId": "12345678",
  "event": {
    "id": 555,
    "deviceId": 42,
    "type": "geofenceEnter",
    "eventTime": "2026-11-01T08:15:00.000+00:00",
    "positionId": 987700,
    "geofenceId": 7,
    "attributes": {}
  },
  "position": {
    "id": 987700,
    "deviceId": 42,
    "latitude": 39.9042,
    "longitude": 116.4074,
    "fixTime": "2026-11-01T08:14:58.000+00:00",
    "attributes": { "batteryLevel": 78 }
  },
  "message": { "title": "围栏进入", "body": "京A·12345 进入「公司」", "digest": "..." },
  "issuedAt": 1793513700000
}
```

校验要点：

1. 校验 HMAC（常量时间比较），失败返回 401；
2. `event.id` 做幂等（Redis `SETNX push:event:<id>`，TTL 24h）；
3. 只有 `userId` 在该网关注册过别名才推送；
4. 返回 2xx 后 Traccar 认为成功；非 2xx 只记录日志，不自动重试。

### 2.2 别名注册（安全契约，见安全整改 C-1/C-2/H-2）

别名必须由网关签发随机盐，**不可由客户端自行编造**（否则 `u5@1` 这类
可枚举别名会让任何人订阅到他人的事件推送）。

**第 1 步：申请别名盐**（App 登录后）：

```http
POST /v1/alias-salt
Authorization: Bearer <traccar-session-token>   # 网关反查 userId
Content-Type: application/json

{ "serverId": 1 }
```

响应：

```json
{ "salt": "Ab12Cd34Ef56Gh78Ij90Kl12Mn34Op56", "alias": "u1@1.Ab12…Op56" }
```

- 网关用 Traccar 会话 Token 调 `GET /api/session` 校验身份；
- 盐值 128bit 随机，TTL 180 天（到期自动轮换）；
- App 把盐值存 Secure Storage（键 `push.aliasSalt.<serverId>`）。

**第 2 步：注册别名**：

```http
POST /v1/aliases
Authorization: Bearer <traccar-session-token>
Content-Type: application/json

{
  "alias": "u1@1.Ab12Cd34…",
  "platform": "android",
  "vendor": "xiaomi",
  "appVersion": "1.0.0",
  "deviceModel": "Xiaomi 14"
}
```

- 网关校验：alias 形如 `u{userId}@{serverId}.{salt}`，且 `userId` 必须
  等于当前已认证用户（403 否则）、盐值必须是本网关签发（403 否则）；
- 退出登录调用 `DELETE /v1/aliases/{alias}`（同样只能删自己的）；
- App **不持有** `GATEWAY_ADMIN_TOKEN` —— 那是内部运维令牌。

### 2.3 下发给极光

```http
POST https://api.jpush.cn/v3/push
Authorization: Basic base64(appKey:masterSecret)
```

```json
{
  "platform": ["android", "ios"],
  "audience": { "alias": ["u1@1"] },
  "notification": {
    "android": {
      "alert": "京A·12345 进入「公司」",
      "title": "围栏进入",
      "extras": { "eventId": "555", "deviceId": "42" }
    },
    "ios": {
      "alert": "京A·12345 进入「公司」",
      "sound": "default",
      "extras": { "eventId": "555", "deviceId": "42" }
    }
  },
  "options": {
    "time_to_live": 3600,
    "apns_production": true
  }
}
```

> 厂商通道离线消息必须把业务字段放在 `extras`，App 侧统一从 `extras` 解析
> `eventId` / `command`。

## 3. 网关最小实现

本目录提供了零依赖 Node.js 参考实现 `gateway.js`（安全整改后的版本）。

**启动要求**（缺失即拒绝启动，fail-closed）：

```bash
TRACCAR_WEBHOOK_SECRET=<与 traccar.xml 一致> GATEWAY_ADMIN_TOKEN=<32+ 随机值，仅内部运维> TRACCAR_API_BASE=https://track.example.com JPUSH_APP_KEY=… JPUSH_MASTER_SECRET=… COMMAND_HMAC_KEY=<32+ 随机值，与 App --dart-define 一致> node gateway.js
```

| 能力 | 实现 |
|---|---|
| 鉴权 | Traccar → 网关 HMAC（常量时间比较）；App → 网关用 Traccar 会话反查 |
| 归属 | 别名必须 `u{userId}@{serverId}.{salt}` 且 userId=认证用户（C-2/H-2） |
| 幂等 | 内存 Map（单实例）→ 生产换 Redis `push:event:<eventId>` |
| 限流 | 单别名 60 条/分钟 |
| 模板 | 按 `event.type` 渲染中英文案 |
| 容量 | 别名/幂等/限流表有上限 + TTL 清扫（M-2） |
| 指令签名 | 下行 `command` 附 HMAC（`userId\|command\|issuedAt`，H-4） |
| 多服务器 | alias 带 `serverId` |

本地联调：

```bash
bash server/gateway/test-gateway.sh
```

> 内存 Map 只适用于单实例；多实例请把 `aliases`/`seenEvents`/`salts`
> 换成 Redis（键结构与代码内注释一致）。

## 4. 本地联调

```bash
# 模拟 Traccar 调用
BODY='{"version":1,"userId":1,"deviceId":42,"event":{"id":555,"type":"geofenceEnter"},"message":{"title":"测试","body":"hello"}}'
SECRET='dev-secret'
SIG=$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $2}')

curl -i -X POST http://localhost:8080/v1/events \
  -H 'Content-Type: application/json' \
  -H "X-Traccar-Signature: sha256=$SIG" \
  -d "$BODY"
```

## 5. 注意

- 这个补丁让服务端从「官方 Traccar」变成**自维护分支**，升级 Traccar 时需要重新应用；
- 若不想维护分支，备选方案是网关轮询 `/api/reports/events`，但有延迟与配额成本；
- 不要把极光 Master Secret / COMMAND_HMAC_KEY 放进 App 或客户端仓库，只放服务端环境变量；
- **远程指令通道默认关闭**：App 未配置 `COMMAND_HMAC_KEY`（dart-define）时拒绝一切指令（fail-closed，H-4）；网关与 App 的密钥必须一致；
- 网关强制 HTTPS 上游（`TRACCAR_API_BASE`），本地联调用 `GATEWAY_ALLOW_INSECURE_DEV=1` 显式豁免。

## 6. 网关参考实现

`server/gateway/gateway.js`：零依赖 Node.js（>= 18）实现，包含
HMAC 常量时间校验、`event.id` 幂等（24h）、单用户限流（60 条/分钟，
超出合并）、按 `event.type` 模板渲染、极光 REST 下发（未配 Key 时 dry-run）。

```bash
# 本地联调启动（弱配置必须显式声明 GATEWAY_ALLOW_INSECURE_DEV=1，
# 生产环境缺失任何必填项会拒绝启动 —— fail-closed）：
GATEWAY_PORT=8090 TRACCAR_WEBHOOK_SECRET=dev-secret GATEWAY_ADMIN_TOKEN=dev-admin-token-0000000000000000 TRACCAR_API_BASE=http://localhost:1 COMMAND_HMAC_KEY=dev-command-key GATEWAY_ALLOW_INSECURE_DEV=1 node server/gateway/gateway.js

# 一键联调（HMAC/幂等/401/别名归属校验全链路）
bash server/gateway/test-gateway.sh
```

环境变量：

| 变量 | 说明 |
|---|---|
| `GATEWAY_PORT` | 监听端口（默认 8080） |
| `TRACCAR_WEBHOOK_SECRET` | 与 `notificator.webhook.secret` 一致 |
| `JPUSH_APP_KEY` / `JPUSH_MASTER_SECRET` | 极光凭据（仅服务端） |
| `GATEWAY_ADMIN_TOKEN` | App 注册别名的 Bearer Token（生产换短期 JWT） |

生产替换点：幂等与别名存储改 Redis（多实例）、免打扰时段、到达回执。

> Node 未安装时，联调脚本会跳过（`node: command not found`）；
> 本仓库 CI 不覆盖网关，部署时在服务器上跑一次 `test-gateway.sh`。
