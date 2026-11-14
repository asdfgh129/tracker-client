# 17 · 客户端 ↔ 服务端协同对齐审计报告

> 2026-11-14 · TrackerOne 0.4.0（功能补齐后）↔ tracker-server 6.16.0-CN-1.1 的
> 协议级对齐审计。审计范围：5056 消息通道、REST API、WebSocket `/api/socket`、
> 推送链路（事件通知 / 指令下行 / 好友邀请唤醒）、认证会话、位置上报与坐标归一化，
> 共 60+ 协议接触点；证据均为逐文件核对（文件:行号）。
> 本文 §1–§4 为首轮审计结论，§5 为整改记录与复测结果。

## 1. 总体结论

**六条主链路在默认部署配置（`location.coordinateSystem=wgs84`）下全部对齐**，
两端版本的互为对方的改动都能闭环：

- 服务端为客户端做的适配全部就位：`POST /api/session/token` 的 `expiration`
  QueryParam 化、`GET /api/session` 的 Bearer SecurityContext 回退、
  `/api/reports/events` 空 `type` 归一化、`friends.list` 补设备 `id` 字段、
  `GET /api/server` 注入 `version`；
- 客户端为服务端做的对接全部就位：NotificatorWebhook（tracker-server 内置）→
  网关契约 → 极光 extras → 客户端解析/验签/深链的闭环。

首轮发现 **2 个功能级缺口（P1）、2 个契约级偏差（P2）、4 个健壮性小项（P3）**，
复核中另发现 **1 个客户端解析 bug（版本探测读错层级）**，无阻塞项。
全部整改见 §5。

## 2. 对齐矩阵（已验证 ✅ 的关键点）

| 链路 | 对齐证据 |
|---|---|
| **5056 好友通道** | 客户端发送的 9 种 type（`auth/register/friends.request/accept/reject/remove/location.request/location.reply`）与服务端 `MessagingManager` 分发 switch 完全一致；`friends.list` 的 `pending_in/pending_out` 状态、设备 `id` 字段（messaging_client.dart FriendEntry）、`location.request` 离线回退 `position+lastTime`、定位回执 `timeout/declined/update` 三态均对齐 |
| **指令下行** | 三方 HMAC 契约一致：服务端 202 排队路径（`CommandResource` 组发/单发两处挂点）→ `CommandWebhookNotifier` 最小 payload → 网关 `signCommand` = HMAC-SHA256(`userId\|command\|issuedAt`) base64url（gateway.js）→ 客户端验签（command_center.dart）逐字节同构；±5min 防重放、`factoryReset` 二次确认、锁屏/未认证拒绝均一致。在线设备因无 CommandSender 也会走队列 202（`CommandsManager.sendCommand`），无投递死角 |
| **事件推送** | `WebhookSender` HMAC 头 `sha256=hex`、HTTPS 强制、缺密钥 fail-closed 与网关 `verifySignature` 一致；客户端 extras 解析 `eventId/deviceId/command/title/body` 与网关 extras 键完全匹配；深链 `/event/{id}` ↔ `GET /api/events/{id}` 闭环 |
| **别名注册** | `POST /v1/alias-salt` → `POST /v1/aliases` → `DELETE /v1/aliases/{alias}` 全流程；客户端盐长≥16、`commandSecret` 长≥32 校验；登出先删别名再清 Secure Storage 的顺序正确 |
| **REST** | 客户端全部 REST 调用端点在服务端存在且参数兼容（含无参 `GET /api/positions` 走全设备最新位置分支）；`session/token` 不传 expiration 由服务端兜底 7 天 |
| **WebSocket** | `?token=` 认证、`positions/devices/events` 三键订阅、连接初始快照、keepalive `{}` 忽略，均对齐 |
| **坐标系** | 默认 `wgs84` 模式下：客户端数据层 WGS-84 + 渲染层转 GCJ-02，与服务端存储/广播原样下发一致；`setup/traccar.xml`、release conf、debug.xml 均为 `wgs84`（服务端首轮审计已修复 debug.xml 陷阱） |

## 3. 首轮差异清单

### P1 — 功能级缺口

1. **`friendInvite` 唤醒推送客户端无专门处理**。服务端 CN-1.1 对离线目标发
   `event.type=friendInvite`（无 `event.id`），网关 extras 带了 `type` 字段，
   但客户端 `PushRouter` 对无 `eventId` 的推送直接忽略——全库无 `friendInvite`
   命中。后果：点开通知只回默认页，靠 messaging 重连拉 `friends.list` 才能看到
   申请（与服务端「点开 App 重连 5056 处理」的设计意图勉强自洽），但深链不落
   好友页、网关塞进 extras 的 `type` 字段客户端从不消费。
2. **README 宣称的 OIDC 登录客户端不存在**。tracker-server 同时具备 OIDC RP
   （`/api/session/openid/auth`+`callback`）与 OP（`OidcResource` 四端点），
   客户端 README 写「OIDC、Token 登录」，但 lib/ 无任何 OIDC 代码。
   同理 **TOTP**：服务端支持 401+`WWW-Authenticate: TOTP` 二次验证，客户端登录
   不发 `code` 参数——开启 TOTP 的账号在 App 上无法登录。

### P2 — 契约级偏差

3. **`X-Locale` 头契约单方面失效**。`server/README.md` 明确「webhook 头
   `X-Locale` 决定通知文案语言」，网关也读取（默认 `zh`），但 tracker-server 的
   `WebhookSender` 从不发送该头——文案语言实际恒为中文，文档承诺超出实现。
4. **gcj02 模式与 TrackerOne 隐性不兼容**。服务端 `location.coordinateSystem=gcj02`
   时：入站（5055 全协议 + 5056 `location.reply/update`）按 GCJ-02 假设反算，
   出站（`location.push`/`friends.list`）转 GCJ-02。而 TrackerOne 全链路只发/只收
   WGS-84 且无服务端坐标系感知——一旦运维开启 gcj02 模式，自身轨迹与好友定位
   将整体偏移约 500m 且无任何告警。当前默认值安全，属条件性风险。

### P3 — 健壮性小项

5. **5056 错误 reason 分支不全**：客户端只特判 `password_mismatch/unknown_device/
   connection_replaced/not_authenticated`，`device_disabled` 落入重连分支形成
   ≤30s 间隔的无意义重连循环（禁用设备不会恢复）。
6. **客户端从不发送 `location.update`**（上报走 5055 SDK），应答分支无注释说明，
   属保留的协议完整性分支。
7. **网关别名注册未传 `vendor/deviceModel`**：契约文档有此二字段，客户端只传
   `alias/platform/appVersion`——网关侧按厂商通道排障的诊断价值损失。
8. **服务端能力富余**（`ShareResource` 临时分享、视频流、statistics/audit 等）：
   PRD 未要求客户端使用，非缺口，无需处理。

## 4. 复核中的新发现（客户端 bug）

9. **版本探测读错 JSON 层级**。Traccar 模型 attributes 经 Jackson 序列化为
   **嵌套**对象（`attributes.version`），而客户端 `refreshServerInfo` 与
   `ServerProfileController.probe` 均读顶层 `server['version']`——真实服务端上
   恒为 null，诊断页版本一直显示 `-`（`GET /api/server` 冒烟时以嵌套路径读到过，
   混淆了两端认知）。

## 5. 整改记录（本轮全部完成）

| # | 整改 | 位置 |
|---|---|---|
| P1-1 | `PushMessage` 增加 `type` 字段与 `isFriendInvite`；`PendingPushIntent` 增加 `friendInvite`；`PushRouter` 对 friendInvite 意图路由/缓存；app 层落到 `/friends` 并触发 `refreshFromPush()` 刷新 | push_gateway.dart、push_router.dart、app.dart、friends_controller.dart |
| P1-2 | TOTP 两步验证：`login()` 支持 `code` 参数并识别 401+`WWW-Authenticate: TOTP` 抛 `TotpRequiredFailure`；登录页弹码重试；README 收敛 OIDC 宣称（标注为服务端能力、客户端未接入） | traccar_api.dart、failures.dart、session_controller.dart、login_screen.dart、l10n ×2、README.md |
| P2-3 | 三处文档改为如实描述：网关支持 `X-Locale` 但服务端不发送、实际恒为中文 | server/README.md ×2、docs/16 |
| P2-4 | 服务端 `GET /api/server` attributes 暴露 `coordinateSystem`（默认 wgs84）；客户端解析并存 Prefs，诊断页对 gcj02 显示不兼容告警；服务端 design-cn.md 补兼容性警告 | ServerResource.java、ApiIntegrationTest、session_controller.dart、diagnostics_screen.dart、design-cn.md |
| 新发现 9 | 两处改为读嵌套 `attributes.version`（保留顶层兜底） | session_controller.dart、server_profile_controller.dart |
| P3-5 | `device_disabled` / `invalid_unique_id` 并入永久失败（不再重连循环） | messaging_client.dart |
| P3-6 | `location.update` 应答分支补注释（协议完整性保留） | messaging_client.dart |
| P3-7 | 别名注册携带 `vendor`/`deviceModel`（device_info_plus，best-effort）；网关参考实现补存 `deviceModel`（原先只读 vendor，与 README §2.2 契约不一致） | push_service.dart、gateway.js |
| P3-8 | 无需处理（服务端能力富余，PRD 未要求） | — |

### 复测结果

- `flutter analyze`：0 issues。
- `flutter test`：**96 用例全绿**（本轮新增用例：PushRouter friendInvite
  路由/缓存/放行 ×4、PushMessage friendInvite 解析 ×2、5056 永久失败
  reason ×1、ServerInfo 嵌套提取 ×3）。
- tracker-server `./gradlew test`：**87 用例全绿**（1 例存量跳过；含
  ApiIntegrationTest 对 `attributes.coordinateSystem` 的断言），
  checkstyle main+test 通过（顺带修复存量违例：MessagingIntegrationTest
  无用导入）。
- 复核方式：对 §2 对齐矩阵逐条重新核对修改后的代码；六条链路无回归。
- 已知边界：推送网关（`server/gateway/gateway.js`）的 `deviceModel` 存储补丁
  未在本机联调（本机无 Node 环境，仓库 CI 亦不覆盖网关）——改动为镜像
  `vendor` 字段的读取与存储两行；部署时按惯例在服务器执行一次
  `bash server/gateway/test-gateway.sh`。

### 两端版本对应

- tracker-client `0.4.1`（CHANGELOG 0.4.1：对齐审计整改）
- tracker-server `6.16.0-CN-1.2`（CHANGELOG CN-1.2：coordinateSystem 暴露 + 文档）
