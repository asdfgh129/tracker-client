# Changelog

## 0.4.1（客户端 ↔ 服务端协同对齐审计整改）

> 审计报告与整改记录见 [docs/17-client-server-alignment-audit.md](docs/17-client-server-alignment-audit.md)；
> 服务端对应版本 6.16.0-CN-1.2。

### 新增

- **TOTP 两步验证登录**：服务端 401 + `WWW-Authenticate: TOTP` 时弹出验证码
  输入并携带 `code` 重试（`POST /api/session` form 字段）；新增
  `TotpRequiredFailure` 与中英文案。开启 TOTP 的账号此前在 App 上无法登录
- **好友邀请唤醒深链（P1-1）**：`PushMessage` 解析网关 extras 的 `type` 字段，
  `type=friendInvite` 的推送（无 eventId，此前被静默忽略）现落到好友页并
  触发好友列表刷新，与服务端 CN-1.1 邀请唤醒链路闭环
- **gcj02 部署告警（P2-4）**：诊断页读取 `/api/server`
  `attributes.coordinateSystem`（服务端 CN-1.2 暴露），gcj02 模式显示
  「与 TrackerOne 不兼容、位置偏移约 500m」告警

### 修复

- **服务器版本探测恒为空（复核新发现）**：Traccar 模型 attributes 为嵌套
  JSON（`attributes.version`），客户端此前读顶层字段恒 null，诊断页版本
  一直显示 `-`；两处（会话探测 + 连接测试）改为嵌套读取（顶层兜底）
- 5056 通道 `device_disabled` / `invalid_unique_id` 归入永久失败，
  不再进入重连循环（P3-5）
- 网关别名注册补传 `vendor` / `deviceModel`（device_info_plus，best-effort，
  P3-7）；网关参考实现（`server/gateway/gateway.js`）补存 `deviceModel`，
  与 README §2.2 契约一致

### 文档

- 新增 **docs/18 两端实现功能详细清单**：客户端 12 业务域逐域盘点 +
  服务端（tracker-server CN-1.2）模块清单 + 客户端功能↔服务端能力映射表
- 收敛 OIDC 宣称：README 能力行标注 OIDC 为服务端能力、客户端未接入
- `server/README.md` 与 `docs/16` 的 `X-Locale` 契约改为如实描述：
  网关支持但 tracker-server 不发送，文案实际恒为中文（P2-3）
- `location.update` 应答分支补注释（本端上报走 5055，保留分支仅为协议完整性）

## 0.4.0（发布工程就绪 + 合并 opencode 线能力）

### 发布工程（阻塞项清零）

- **包名定稿 `com.trackerone.app`**（ADR-015）：applicationId / namespace /
  iOS Bundle ID / brand.dart / MainActivity 包路径全部切换；相关文档同步
- **高德 Android Key 与极光 AppKey 内置**（自 opencode 线照搬，均绑定正式包名）：
  `BuildConfig.amapAndroidKey`、`BuildConfig.jpushAppKey`、Gradle `JPUSH_APPKEY`
  均有正式默认值，仍可用 `--dart-define` / `-P` 覆盖；`PUSH_PROVIDER` 默认 `jpush`
- 版本号同步：pubspec 0.2.0+1 → 0.4.0+1（修复与 CHANGELOG 脱节）
- iOS 合规补件（自 opencode 线移植）：`PrivacyInfo.xcprivacy`、
  `ExportOptions.plist.example`、`NSLocalNetworkUsageDescription`（局域网 Traccar）
- Android 合规补件：显式移除 AD_ID/AdServices/InstallReferrer 广告权限；
  camera/GPS `uses-feature` 非强制（避免商店过滤设备）
- `android/key.properties.example` 模板；`tool/release_check.sh` 发布自检
  （ARB/包名/敏感文件/analyze/test/网关语法）
- CI 增加 iOS 编译验证任务（macOS runner，`--no-codesign`）

### 安全修复

- **远程指令签名改为每别名独立密钥（H-4 升级）**：网关注册时签发
  `commandSecret`（HTTPS + 会话鉴权下发），App 存 Secure Storage 并用于验签；
  删除打进客户端的静态共享 `COMMAND_HMAC_KEY`，反编译不再泄露指令签名能力；
  双侧 fail-closed（无密钥别名网关拒发、客户端拒执行）
- **修复推送别名注册从未成功**：会话钩子未携带 Traccar Token，网关反查恒 401
- **隐私政策版本号机制（CN-05）**：同意记录升级为「布尔 + 政策版本号」，
  条款实质变更递增版本即强制全员重新过隐私门；存量用户自动重确认一次
- 5056 消息通道超时语义：`_call` 超时不再伪造 `{success:false}` 应答，
  改抛 `MessagingFailure`（请求已发出、结果未知）；断连失败也统一为该类型；
  listFriends 增加 12s 超时防悬挂

### 合并 opencode 线能力

- **指令离线发件箱**（A 线持久指令队列语义，复用 PendingActions 表）：
  可重试类失败（网络/超时/5xx/429）自动入箱，会话就绪/回前台/发送成功时补发；
  不可重试类（401/403/404/参数）仍即时报错
- **缩放感知地图聚合（MAP-04）**：`clusterMarkers` 纯函数（zoom≥17 不聚合、
  本机永不聚合、橙色数量标记），替换原 >50 台才生效且未渲染的死代码；
  点选聚合选中簇内设备；4 个新单测
- **Node 网关韧性升级**（自 A 线 Go 网关移植）：极光失败指数退避后台重试
  ≤3 次 + 死信（7 天 TTL）+ `POST /v1/flush` 管理令牌补发；限流超限合并延后
  补发（不丢弃）；webhook `X-Locale` 头中英双语模板
- **事件补拉覆盖全部设备**：优先 `/api/events?from&to` 单请求全量，
  失败回退逐设备循环（原实现只取前 10 个设备）
- **厂商保活指南 + 真实厂商识别（自 A 线移植）**：新增电池优化引导页
  （`/diagnostics/battery`，三步引导 + 厂商专属路径 + 电池豁免申请入口）；
  修复 `VendorHintsResolver.detectFromPlatform` 拿不到 manufacturer 时永远
  返回 generic 的缺陷——诊断页/权限向导/设置页三处厂商提示按真实机型生效
  （`deviceVendorHintsProvider`，device_info_plus 注入）；诊断页电池优化
  豁免状态从硬编码 false 改为真实读取
- 诊断页新增指令发件箱积压量（`AppDatabase.commandOutboxCount`）；
  网关新增死信查看端点 `GET /v1/dead`（管理令牌，别名盐值脱敏）
- 运营文档移植：docs/13 真机测试矩阵、docs/14 发布检查清单、
  docs/15 凭据与签名清单（含已内置 Key 与 SHA1）、docs/16 推送运维手册
  （适配 Node 网关）；`server/README.md` 契约同步

### 已知限制

- 网关免打扰时段（QUIET_HOURS）与 Redis 多实例尚未实现（见 docs/16）
- 网关与 App 需同版本上线（commandSecret 契约变更）
- 指令发件箱暂无队列管理 UI（诊断页可见积压量；管理界面留待后续）


## 0.3.0（好友体系 + 通信补环）

### 好友体系（5056 消息通道）

- `core/network/messaging_client.dart`：5056 WebSocket 客户端——设备认证
  （uniqueId + 设备密码）、请求-应答按 type 关联、指数退避重连（1s→30s±20%）、
  password_mismatch 置 failed 不自动重试（明确提示管理员重置路径）
- 好友全流程：按对方 8 位 uniqueId 加好友、接受/拒绝申请（实时横幅 + 好友页双入口）、
  删除好友、friends.list 快照与 drift 缓存
- 实时定位：好友位置广播落库（`location.push{status:"update"}`）、发起定位请求
  （position/timeout/declined/offline 四态反馈）、收到请求全局弹窗 →
  同意分享本机位置 / 拒绝
- 好友页（`features/friends/`）+ 底部「好友」tab（track 模式隐藏，需服务器+登录守卫）
- 地图好友图层：accepted 且有位置的好友上地图（`FriendMarker`；好友设备可能
  不在 REST 设备列表——按 uniqueId 独立建模）
- 存储升级：drift schemaVersion 2 `friend_rows`（PK serverId+uniqueId）+ 迁移分支
- 通道生命周期：前台连接；跟踪运行中后台保活；设备密码首次连接自动生成并注册
  （Secure Storage `messaging.password.<serverId>`，防 8 位 uniqueId 被冒用）
- 11 个新单测：消息编解码/关联/幂等/容错、messagingUrl 派生（69 用例全绿）

### 通信与装配补环（与服务端对齐）

- PushRouter 三回调接线（事件导航/应用内横幅/指令执行）+ consumePending 会话放行；
  此前推送消息解析后不产生任何 UI 效果
- 深链接入：`DeepLinkHandler.listenAppLinks` 实际调用（冷启动+运行期）；
  `trackerone://server?url=` 传递并预填服务器地址
- 前台事件横幅（WS 与推送双源、eventId 去重、状态类事件降噪）
- factoryReset 远程指令：横幅二次确认后执行
- 登出/切换服务器撤销推送网关别名（防串号，docs/09 §3.4）
- JPush 原生接线：AndroidManifest meta-data 占位符（gradle `-PJPUSH_APPKEY` 注入）、
  iOS `applyPushAuthority`；runbook §9 更新 AppKey 注入与 iOS capability 步骤
- 通知规则管理：`/api/notifications` CRUD + 设置子页——管理员创建的用户
  可自助开启事件提醒与离线推送（服务端默认规则只覆盖自注册用户）

### 服务端（tracker-server CN-1.1，见该仓库 CHANGELOG）

- 指令下行 webhook（离线排队 → 网关 → 极光 extras，App 验签执行）
- 好友位置实时广播（`messaging.locationBroadcast`，默认开）
- 好友邀请离线唤醒（friendInvite webhook）
- friends.list 响应补充设备 id

### 文档

- server/README.md：payload 契约对齐最小化实现（M-10）、GATEWAY_ADMIN_TOKEN
  表述纠正（App 用 Traccar 会话 Bearer）、标注正式实现位于 tracker-server

## 0.2.0（MVP 实现）

### 应用层（对齐 docs/01 PRD 全部 P0）

- 服务器档案（AUTH-01/02/03/09/11）：地址自动推导（`:8082` → `:5055`）、
  测试连接（成功/401/TLS/超时/非 Traccar 五态）、二维码导入（URL/JSON/深链）、
  多档案存储与切换
- 认证（AUTH-04～07/10）：密码登录 → Cookie 换 Token → Secure Storage；
  Token 直接登录；401 统一过期处理；生物识别锁（local_auth）；登出撤销 Token
- 引导（CN-05/06）：隐私同意门（同意前不初始化任何第三方 SDK）、
  模式选择、三步权限向导（通知 → 前台定位 → 后台 + 运动）、厂商省电引导
- 设备实时（MAP-01/03）：REST 快照 + WebSocket 增量 + drift 缓存三路合并；
  断线指数退避重连（1s→30s ±20% 抖动）；后台断开省电
- 实时地图（MAP-02～12）：标记/尾迹（最近 50 点）/网格聚合（>50 标记）/
  跟随模式/搜索筛选/设备底部卡片/离线横幅
- 历史回放（HIS-01～08）：分段查询（≤2 天/段）+ fixTime 幂等去重、
  Douglas–Peucker 抽稀、停留检测（速度 + 半径聚类）、回放（倍速/进度）、
  速度/海拔/电量曲线、GPX/KML/CSV 导出（系统分享）
- 事件（EVT-01/02/06）：drift 缓存（30 天保留）、筛选/未读、WS 实时、
  `/api/reports/events` 补拉兜底
- 远程指令（DEV-04～06）：发送（200/202 区分）、本机接收执行
  （positionSingle/Periodic/Stop）、factoryReset 二次确认、审计日志
- 本机跟踪（TRK-01～16）：8 位 uniqueId 生成/绑定（查/建/403 降级）、
  状态机（未配置/停止/启动中/运行中/受限/失败）、配置热更新、
  5 组预设、SOS（alarm=sos）、队列积压提示（>100）
- 推送（EVT-03/04、CN-03/04）：PushRouter（前台横幅/点击直达/未登录缓存/
  登录后消费）、极光网关别名注册（`u{userId}@{serverId}`）、
  Noop 降级（未配置时应用内事件仍可用）
- 设置（SET-01～06、CN-07/09）：主题/语言/单位/地图样式、
  个人信息收集清单 + SDK 清单、本地数据删除、退出登录
- 诊断（SET-04）：结论引擎（权限/服务/定位/上报/实时五步）、
  权限矩阵、队列、服务器可达性、日志查看与导出
- 关于（CN-08）：APP 备案号与地图审图号占位（`--dart-define` 注入真实值）
- i18n：en/zh 全量 ARB（各 395 条消息键），全部 UI 走 l10n，无硬编码文案

### 网络与存储

- `TraccarApi`：REST 全量封装（会话/设备/位置/事件/指令/用户）
- 拦截器：Auth（Bearer 注入 + 401 登出）、Retry（仅 GET + 幂等，指数退避）、
  ErrorMapping（DioException → AppFailure 密封类）、脱敏日志（token/坐标）
- 自签名证书策略：条件导入（IO 平台实现，默认严格校验）
- `SocketClient`：单连接、快照语义、(deviceId, fixTime) 位置幂等、
  eventId 事件幂等、解析失败不断连、suspend/resume/disconnect
- drift 数据库：server_profiles/devices/positions/events/pending_actions/
  tracking_snapshots 六表；保留策略（位置 7 天、事件 30 天）；
  退出登录/删除档案数据清理
- 日志：环形内存缓冲（500 条）+ 文件 sink（10MB 轮转 / 7 天）；
  脱敏规则（credential 对、JWT 形态、坐标 3 位小数）

### 平台与服务端

- `server/gateway/`：零依赖 Node.js 推送网关参考实现
  （HMAC 常量时间比较、eventId 幂等 24h、限流 60/min、模板渲染、极光下行）
- `server/gateway/test-gateway.sh`：HMAC 联调脚本（幂等/401/别名注册）
- GitHub Actions CI：pub get → gen-l10n → build_runner → analyze → test；
  CN 构建开关静态检查（docs/09 §3.9 APK 成分检查拆分后补充）

### 测试

- 坐标转换（既有）+ URL 推导/二维码解析、SocketClient 协议解析与幂等、
  轨迹抽稀/停留检测/里程统计、GPX/KML/CSV 导出、脱敏、诊断结论引擎

### 构建配置

- `--dart-define` 新增：`PUSH_GATEWAY_URL`、`APP_FILING_NUMBER`、
  `MAP_APPROVAL_NUMBER`（备案号/审图号占位注入）、
  `COMMAND_HMAC_KEY`（远程指令签名，未配置=指令通道关闭）

### 安全审计整改（MASVS-L1，详见 docs/11）

- **H-7** release 签名：`key.properties` 签名链，缺失时构建失败（防 debug 包流出）
- **H-1** iOS `NSCameraUsageDescription`（扫码崩溃修复）
- **H-3** 明文 HTTP 独立开关 + 二次确认；手工地址统一 scheme 校验
- **H-5** SDK 同意门：Firebase 推迟到隐私同意后初始化；统计开关真实生效；撤回同意停采集；CI 解包断言 CN 包无 firebase/gms
- **H-6** 删除权完整实现（DB+凭据+日志+导出文件+同意记录）；登出走同一清理
- **H-4** 远程指令 HMAC 验签 + 防重放 + 锁定拒执行（fail-closed）
- **C-1/C-2/H-2** 网关重写：无默认令牌、盐值别名（不可枚举）、归属校验、容量上限
- **M-1** `allowBackup=false` + dataExtractionRules 全排除
- **M-3** 日志脱敏加固（15 键白名单/Basic/Base64/JWT）
- **M-4** 裸 debugPrint 清零；**M-5** 导出文件名清洗；**M-7** 二维码导入信任显式化
- **M-8** 生物锁成为真正的数据访问门禁（api() 未解锁抛异常）
- **M-9** CI 最小权限 + Action 锁 SHA + 平台自检；**M-10** 插件 HTTPS 强制/payload 最小化
- **M-2/L-1/L-7** 网关健壮性、intl 锁版本、gitignore 通配

### 性能整改（详见 docs/11 §2）

- 地图渲染 provider 去写副作用（尾迹缓冲移到数据层）
- 历史抽稀结果缓存（10k 点不再逐帧重算）；DP 算法迭代化（防栈溢出）
- 事件表双索引；事件补拉 3 并发；三页 ticker 后台暂停
- `flutter analyze` 0 issues；58 用例全绿；debug APK 构建通过

## 0.1.0

### 初始骨架

- 产品、架构、API、定位、排期、质量文档
- 领域模型、服务器档案、跟踪引擎抽象与 SDK 适配器

### 中国大陆首发方案

- `docs/09` 地图选型、推送架构、备案、合规、商店
- `docs/10` 环境搭建、平台工程、原生配置、M0 验收

### 代码

- 坐标系转换、地图抽象、隐私同意门、高德渲染适配
- `PushGateway` 抽象、极光、FCM、`PushService`
- `NotificatorWebhook.java`（Traccar 补丁）

### 验证状态

- 0.1.0 未编译验证；0.2.0 起 CI（GitHub Actions）+ 本地 `tool/verify.sh` 保证
  analyze/test 全绿
