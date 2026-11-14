# Changelog

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
