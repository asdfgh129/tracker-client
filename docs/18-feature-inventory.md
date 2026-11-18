# 18 · 两端实现功能详细清单（Feature Inventory）

> 2026-11-15 · 对照代码逐域盘点：tracker-client **0.4.1**（Flutter，本项目）与
> tracker-server **6.16.0-CN-1.2**（Traccar-CN fork，配对仓库）。
> 依据：lib/features 12 业务域 + lib/core 基础设施 + 服务端 src 模块；
> 协议级对齐依据见 [docs/17-client-server-alignment-audit.md](17-client-server-alignment-audit.md)。

## 1. 客户端功能清单（tracker-client 0.4.1）

### 1.1 业务域（lib/features，12 个）

**auth · 认证与锁**
- 密码登录（`POST /api/session` form：email/password，Set-Cookie 换长期 Token）
- **TOTP 两步验证**：服务端 401+`WWW-Authenticate: TOTP` 时弹码重试（`code` form 字段，0.4.1）
- Token 直接登录（企业分发 / 扫码；`GET /api/session` 验证）
- **OIDC 企业登录（SSO，0.5.0）**：系统浏览器走 IdP 授权 → 签名 state 携带回跳目标 →
  一次性 code 深链回跳（`trackerone://openid/callback`）→ `POST /api/session/openid/mobile`
  换长期 Token；服务端 `openIdEnabled` 时登录页显隐、`openIdForce` 时提示
- 会话恢复：启动读 Secure Storage → 验证 → 网络失败降级离线只读
- 生物识别锁（local_auth；锁屏期间 API 层拒绝服务，路由守卫 `/lock`）
- 登出：`POST /api/session/token/revoke` → 清 Token/密码 → 撤销推送别名 → 清缓存/日志/导出文件

**onboarding · 引导**
- 模式选择（track/view/both）、隐私同意门（版本号机制，条款变更强制重确认）、权限分步引导向导

**server · 服务器档案**
- 多服务器档案 CRUD（API 与上报地址分离；`https` 强制、明文需显式 allowInsecure、自签名证书仅作用于该档案）
- 连接测试（探测 name/version/延迟；版本读嵌套 `attributes.version`，0.4.1 修复）
- 二维码 / 深链导入（Traccar Client URL、JSON、`trackerone://server`；allowSelfSigned 永不继承）

**tracking · 本机上报**
- TrackingEngine 适配 `traccar_client_sdk`（OsmAnd 协议 POST `:5055`）
- 省电档位（精度/间隔/距离/角度/心跳/停车检测/离线缓冲），开机恢复与前后台策略
- 快捷开关、通知常驻（`TrackerOne → {host}`）
- **SOS**（`alarm=sos` 一键上报）
- 本机设备绑定：8 位 uniqueId 自动生成 → `GET /api/devices?uniqueId=` → 无则 `POST /api/devices`

**devices · 设备管理**
- 设备列表 + 关键字搜索（`GET /api/devices`）
- 最新位置快照（无参 `GET /api/positions`）+ 设备详情页
- WebSocket 实时（`/api/socket?token=`；positions/devices/events 三键；去重上限 5000/1000；指数退避重连 1s→30s±20%；进后台断开省电）

**map · 地图**
- 高德 `amap_map`（中国大陆主图，GCJ-02 仅渲染层转换，数据层 WGS-84）；`flutter_map` 海外/兜底
- 缩放感知聚合（zoom≥17 不聚合、本机永不聚合、数量气泡）
- 轨迹尾迹、跟随模式、设备卡片与快捷指令入口

**friends · 好友互见（5056 消息通道）**
- 通道连接：同 host `:5056` `/messaging`，设备级 auth（uniqueId+密码）；首次自动生成 12 位随机密码并经 `register` 注册（Secure Storage）
- 好友列表（`friends.list`：accepted/pending_in/pending_out + 在线状态 + 最后位置快照）
- 申请 / 同意 / 拒绝 / 删除（`friends.request/accept/reject/remove`；反向 pending 自动互为好友）
- 实时定位请求 / 回复 / 拒绝（`location.request/reply`；请求全局弹窗；离线回退最后已知位置；回执 timeout/declined）
- 好友位置实时广播（`location.push{status:"update"}` → 地图实时刷新）
- 离线邀请推送唤醒：`type=friendInvite` 推送 → 落好友页 + 刷新列表（0.4.1 闭环）

**history · 历史与导出**
- 位置历史分段拉取（≤2 天/段，`GET /api/positions?deviceId&from&to`）
- 路线回放、行程/停留视图、速度曲线
- 轨迹导出 **GPX 1.1 / KML / CSV**（永远 WGS-84）

**events · 事件与推送**
- 事件流：全量 `GET /api/events?from&to` 优先，失败回退逐设备 `/api/reports/events`（3 并发）
- 事件详情（`GET /api/events/{id}`，推送点进直达）
- 前台应用内横幅（不重复弹系统通知）、点击深链 `/event/{id}`
- 通知规则自助管理（`GET/POST/DELETE /api/notifications`，默认 `notificators=web,webhook`）
- 免打扰时段（DND）

**commands · 远程指令**
- 指令下发（`POST /api/commands/send`：200=已发送 / 202=已排队）；类型探测（`GET /api/commands/send`）
- **离线指令下发闭环**：202 → 服务端经推送网关下行 → App 验签执行
- HMAC 验签：每别名独立 `commandSecret`（Secure Storage），HMAC-SHA256(`userId|command|issuedAt`) base64url、常量时间比较、±5 分钟防重放；缺密钥/锁屏/未认证 fail-closed
- 支持执行：`positionSingle` / `positionPeriodic` / `positionStop` / `factoryReset`（二次确认）
- 指令离线发件箱（可重试失败自动入箱，会话就绪补发；401 保留待重登）

**diagnostics · 诊断与可观测**
- 诊断页：权限、socket 状态、服务器版本/坐标系（**gcj02 不兼容告警**，0.4.1）、指令发件箱、厂商电池引导
- 日志脱敏（token/别名/坐标）、文件 sink、导出与擦除
- 崩溃上报（默认 Noop；国内 **Bugly** 0.5.1、海外 Crashlytics；同意门控，上报前经 LogRedactor 脱敏）

**settings · 设置**
- 主题/语言（ARB，中英）/单位、事件通知开关、生物识别开关（AUTH-07；免打扰时段未实现）
- 隐私政策版本门、数据擦除（drift 缓存/日志/导出文件）、关于页（版本/服务端版本）

### 1.2 核心基础设施（lib/core）

| 模块 | 能力 |
|---|---|
| network | REST 客户端（Bearer 注入、401 回调、GET 幂等重试、错误映射、URL 脱敏日志）、SocketClient、MessagingClient（5056）、证书策略（条件导入） |
| push | PushGateway 抽象（jpush/fcm/none）、网关客户端（alias-salt→aliases→delete）、PushRouter（事件/指令/好友邀请路由、冷启动意图缓存）、深链 `trackerone://event|server` |
| map | 坐标系转换（WGS-84↔GCJ-02）、地图抽象层、隐私同意门 |
| storage | drift 七表（含 FriendRows）、SecureStore（按 serverId 隔离）、Prefs、数据擦除 |
| tracking | TrackingEngine 抽象 + SDK 适配 |
| observability | 日志脱敏、文件 sink、崩溃上报 |
| location | 权限服务、厂商电池引导（vivo/华为/小米/OPPO/三星/魅族…） |

### 1.3 平台与工程

- Android 24+（后台定位、开机恢复、`allowNativeHeapPointerTagging=false`、移除广告权限）/ iOS 15+（Background Modes、PrivacyInfo.xcprivacy）
- CI：analyze / test / 平台自检 / CN 成分断言 / iOS 编译（`--no-codesign`）
- 测试：104 用例（协议解析、路由、坐标转换、聚合、脱敏、SDK mock 等）；`flutter analyze` 0 issues
- 推送网关参考实现（`server/gateway/gateway.js`，零依赖 Node）：HMAC 鉴权、幂等、限流合并、重试/死信、双语模板、每别名指令签名

## 2. 服务端功能清单（tracker-server 6.16.0-CN-1.2）

### 2.1 接入端口

| 端口 | 协议 | 说明 |
|---|---|---|
| 8082（可配） | HTTP/REST/WebSocket | Web API + `/api/socket` 实时推送 |
| 5055 | OsmAnd（HTTP） | 位置上报：query（id/lat/lon/timestamp/speed/batt/charge/cell/wifi…任意属性）与 OwnTracks 风格 JSON 双格式；`database.registerUnknown` 自动注册 |
| 5056 | Messaging（WebSocket `/messaging`） | 好友体系消息通道（设备级认证；`messaging.ssl` 可开 TLS） |

### 2.2 REST API（/api，Traccar 6.16 全集 + CN 适配）

- 会话：表单登录（含 TOTP 二次验证）、长期签名 Token（默认 7 天，吊销表）、Token 直接登录、OIDC RP（`session/openid/auth|callback`）；`GET /api/session` 支持 Bearer 反查（CN，推送网关依赖）
- 服务端信息：`GET /api/server`（注入 `attributes.version`、**`attributes.coordinateSystem`**，CN）
- 设备/位置/事件：devices、positions（范围查询 + gpx/csv/kml/kmz 导出）、events
- 报表：reports/route|trips|events|summary|geofences|stops（+xlsx/mail；CN：空 `type=` 归一化全部）
- 指令：commands/send（GET 类型探测 / POST 直发 200、**离线排队 202** + 指令下行推送）
- 通知：notifications CRUD、types/notificators、test/send
- 其余：users（含 TOTP 注册）、permissions、geofences、calendars、drivers、maintenance、orders、attributes/computed、share（临时只读分享）、protocols、statistics、audit、health

### 2.3 WebSocket /api/socket

- `?token=` 或会话认证；连接即推最新位置快照；`{devices|positions|events|logs}` 单键推送；keepalive

### 2.4 5056 消息通道（好友体系）

- 认证：uniqueId+可选密码（盐化迭代 SHA-256、恒时比较；authTimeout 30s；重复连接顶替）
- 密码管理：`register`（设/改/清密码，弱密码拒绝）
- 好友状态机：`friends.request/accept/reject/remove/list`（pending→accepted；反向 pending 自动互认；`messaging.maxFriends` 上限；list 附设备 id/在线/最后位置）
- 定位：`location.request`（在线推送/离线回退最后位置/超时回执）、`location.reply`（正常/declined）、`location.update`（等价 5055 的上报路径）
- **实时广播**：位置入库后向在线 accepted 好友推 `location.push{status:"update"}`（`messaging.locationBroadcast`，覆盖 5055 与 messaging 两条路径，异常隔离）
- **离线唤醒**：`friends.request` 目标不在线时经推送网关下发极光通知（申请仍持久化 pending_in）

### 2.5 通知栈与推送链路

- NotificatorManager：command/web/mail/sms/**webhook**
- NotificatorWebhook：最小化 payload（PIPL 数据最小化，不含 email/uniqueId/完整 position）、HTML 清洗（去 unsubscribe 链接）
- WebhookSender（共享投递组件）：强制 HTTPS（allowHttp 豁免）、HMAC-SHA256 `X-Traccar-Signature`、缺密钥 fail-closed、超时/日志截断
- CommandWebhookNotifier：REST 202 排队路径挂点，指令下行到网关（`notificator.webhook.commands` 开关）
- 自注册用户自动创建默认通知规则（10 类事件，`notificators=web[,webhook]`）

### 2.6 事件管线与处理

- 事件：motion/ignition/overspeed/geofence/alarm/maintenance/deviceOnline/deviceOffline/commandResult 等（`event.status.enable`）
- 管线：坐标归一化（`location.coordinateSystem=wgs84|gcj02`，原始值记 rawLatitude/rawLongitude）→ 过滤/去重/精度 → 距离/运动处理 → 批量入库 → 事件循环

### 2.7 存储与运维

- 存储：H2（默认零依赖）/ MySQL / 内存（测试）；`tc_friends`、`tc_revoked_token`（Liquibase）
- 多实例：Multicast 广播（devices/positions/invalidate）
- 可观测：统计（statistics）、审计日志（audit）、健康检查（/api/health）、事件转发（JSON EventForwarder）
- 认证补充：OIDC Provider（authorize/token/userinfo/jwks）、TOTP、服务账号 Token
- 配置族：`messaging.*`（port/authTimeout/requestTimeout/maxFriends/locationBroadcast/ssl）、`notificator.webhook.*`（url/secret/timeoutSeconds/allowHttp/commands）、`location.coordinateSystem`、`database.registerUnknown`、`openid.*`
- 测试：93 用例（API 集成 13 项、messaging 集成、好友状态机、坐标转换、协议解码、OIDC 签名 state…）+ checkstyle

## 3. 客户端功能 ↔ 服务端能力映射

| 客户端功能 | 依赖的服务端能力 | 通道 |
|---|---|---|
| 登录/Token/TOTP | session 系列 + TOTP 质询 | REST |
| 服务器档案探测（版本/坐标系） | `GET /api/server` attributes（CN-1.1/1.2 注入） | REST |
| 设备列表/绑定 | devices + registerUnknown | REST / 5055 |
| 实时地图 | /api/socket 快照与推送 | WebSocket |
| 历史轨迹/导出 | positions 范围查询 | REST |
| 事件流/详情/通知规则 | events + notifications（自注册默认规则兜底） | REST |
| 好友互见全流程 | 5056 消息通道（状态机/广播/邀请唤醒） | 5056 |
| 好友离线邀请唤醒 | friends.request→网关→极光（CN-1.1） | webhook→JPush |
| 事件推送（围栏/告警/超速/SOS） | 事件管线 + NotificatorWebhook→网关 | webhook→JPush |
| 远程指令（离线） | 202 排队 + CommandWebhookNotifier→网关→App 验签执行 | REST+webhook |
| 本机上报 | OsmAnd :5055（+location.update 等价路径） | 5055 |
| 别名注册/推送接收 | `GET /api/session` Bearer 反查（CN-1.0）+ 网关 | 网关 |
| 坐标渲染（GCJ-02） | `location.coordinateSystem=wgs84` 约定（gcj02 时诊断页告警） | 全链路 |

## 4. 明确不做 / 待外部依赖

- 客户端未接入：TOTP 开通管理（`users/totp` 供服务端/Web 侧）、`location.update` 主动上报（保留协议分支）、ShareResource 临时分享、视频流
  （OIDC 企业登录已于 0.5.0 接入，见 docs/04 §2.3）
- 待外部配置：高德/极光正式 Key（已内置正式包名绑定值）、PUSH_GATEWAY_URL、备案号、隐私政策 URL（`--dart-define`）
- 网关生产化：内存表换 Redis（多实例）、到达回执（见 server/README.md）
