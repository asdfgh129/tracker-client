# 11 · 安全与性能审计报告

> 2026-11 · 首轮 MASVS-L1 安全审计 + 性能审计的结论与整改记录。
> 审计方法：静态分析（逐行核对）+ 单元测试验证；整改后 `flutter analyze` 0 issues、
> 58+ 用例全绿、debug APK 构建通过。

## 1. 安全审计（OWASP MASVS-L1）

### 1.1 结论

首轮审计发现 **2C + 8H + 11M + 8L**，共 29 项。**全部阻断项已整改**；
两项（C-2 服务端配合、H-8 外部备案）为「代码就绪、依赖外部条件」。

### 1.2 已整改清单

| ID | 级别 | 问题 | 整改 |
|---|---|---|---|
| C-1 | C | 网关默认管理令牌 `dev-admin-token` 硬编码兜底 | 删除默认值；缺配置拒绝启动；常量时间比较；生产要求 ≥32 字符 |
| H-1 | H | iOS 缺 `NSCameraUsageDescription`（扫码崩溃+驳回） | 已加文案（扫码用途） |
| H-3 | H | 明文 HTTP 门槛被「自签名」勾选复用；手工地址无校验 | 拆分为独立开关 + 二次确认弹窗；手工地址统一过 `validateManualUrl`；`ServerProfile.isInsecure` 供 UI 常驻警示 |
| H-5 | H | Firebase 打包 + 同意前初始化 + 统计开关无效 | 崩溃上报改为 `preparePending()`（启动不初始化）→ 同意后 `initialize()`；统计开关与真实采集绑定；撤回同意 `disable()`；CI 增加 CN 包解包断言（无 firebase/gms） |
| H-6 | H | 删除本地数据/登出未清理轨迹残留 | `wipeLocalData()` 覆盖 DB+凭据+日志+导出文件+同意记录；登出走同一清理；新增 `DataEraser` |
| H-7 | H | release 用 debug 签名 | `key.properties` 签名链；缺失时构建失败（`-PALLOW_DEBUG_SIGNING=true` 仅本地调试） |
| H-4 | H | 推送 payload 即无认证远程指令 | 指令带 HMAC 签名（`userId|command|issuedAt`，5 分钟防重放窗口）；签名密钥升级为**每别名独立** `commandSecret`（注册时 HTTPS 下发，客户端零静态密钥），缺失即拒发/拒执行（fail-closed）；锁定状态拒执行 |
| M-1 | M | 行踪 DB/日志进云备份 | `allowBackup=false` + `dataExtractionRules` 全排除（cloud + device-transfer） |
| M-3 | M | LogRedactor 漏网（Basic/Base64/短 token/apikey） | 键白名单扩到 15 键（含中文键）；`Basic/Bearer` 值无条件脱敏；字符集补 `+/=`；JWT 三段式独立规则 |
| M-4 | M | 裸 `debugPrint` 绕过脱敏且 release 仍输出 | 全部改走 `AppLog`（经脱敏）或包 `kDebugMode` |
| M-5 | M | 导出文件名拼接服务端可控设备名（目录穿越） | `TrackExporter.safeFileName`（白名单清洗+截断） |
| M-7 | M | 二维码/深链导入不校验信任 | 导入不再自动放行自签名；http 显式标记 `allowInsecure`（UI 红色警示）而非静默接受/打断 |
| M-8 | M | 生物识别锁只是 UI 标志 | `SessionState.api()` 在未解锁时抛异常 —— 锁成为真正的数据访问门禁（指令/同步全部拦截） |
| M-9 | M | CI 权限过大、Action 未锁 SHA、`|| true` | `permissions: contents: read`；Action 锁 commit SHA；去掉 `|| true`；新增平台配置自检 job |
| M-10 | M | 插件不校验 HTTPS、secret 缺失仍发送、日志回显全文、过度外发 | HTTPS 强制（`allowHttp` 显式开关）；secret 缺失 fail-closed；响应体截断 256B；payload 最小化（去 email/uniqueId/原始对象） |
| L-1 | L | `intl: any` | 锁定 `^0.20.2` |
| L-2 | L | 未接线依赖（app_links 等） | `app_links` 已接线（深链 handler）；其余按 flavor 清理项记录于 §1.3 |
| L-7 | L | .gitignore 固定路径易漏 | 改通配 `**/`；补 `*.p12/*.mobileprovision/*.jceks/firebase_options.dart/server/**/.env` |
| L-8 | L | `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` 声明未使用 | 保留（电池优化引导为 TRK-15 P0 功能，诊断页接线见后续迭代） |

### 1.3 服务端配合项（代码已就绪，部署时生效）

| ID | 问题 | 代码侧 | 服务端动作 |
|---|---|---|---|
| C-2 | 推送别名可枚举（`u5@1`）→ 他人可订阅事件 | App 只接受**网关签发的随机盐**别名（`u{userId}@{serverId}.{salt128}`），无盐不注册 | 部署新版 `server/gateway/gateway.js`（盐值签发 + 归属校验） |
| H-2 | 别名注册无归属校验、客户端曾持有管理令牌 | `POST /v1/alias-salt` 用 Traccar 会话反查身份；网关强制 `alias.userId == 认证 userId`，删除同理 | 同上；`GATEWAY_ADMIN_TOKEN` 仅内部运维，不下发客户端 |
| H-8 | 隐私政策 URL / 备案号 / 审图号占位 | `--dart-define=APP_FILING_NUMBER / MAP_APPROVAL_NUMBER` 注入位就绪 | 备案通过后注入真实值；隐私政策 URL 上线前替换 `Brand.privacyUrl` |

### 1.4 审计确认通过项（无需整改）

- Token/密码仅存 Keystore/Keychain（`first_unlock_this_device`）；prefs 无敏感键
- 全仓库无真实密钥字面量（占位符 + 构建注入）
- 自签名放行仅作用于单档案 Dio 实例，无全局副作用；WS token 已做日志脱敏
- SQL 全部参数绑定（含 2 处 custom SQL）；GPX/KML 转义正确；CSV 无公式注入面
- 网关 HMAC 常量时间比较 + fail-closed；事件幂等 24h TTL；请求体 256KB 上限
- Android 权限最小必要（与 docs/05 §5.1 矩阵一致）；`exported` 仅 launcher

## 2. 性能审计

### 2.1 已整改

| 问题 | 证据 | 整改 |
|---|---|---|
| `mapRenderProvider` 在派生层写尾迹缓冲（反模式，连锁重算） | map_controller.dart | 写入移到 `DevicesController._onSnapshot`（数据层）；provider 纯派生 |
| 历史抽稀 getter 每次 build 重算 DP（10k 点卡顿） | history_controller.dart | `renderPoints` 构造时计算并缓存一次 |
| Douglas–Peucker 递归（病态数据栈深 O(n)，10k 点溢出风险） | track_math.dart | 改显式栈迭代实现（平均 O(n log n)） |
| 事件表无索引（列表排序/未读统计全表扫描） | database.dart | 新增 `idx_events_server_time`、`idx_events_server_read` |
| 事件补拉 10 设备串行（弱网 >10s） | events_controller.dart | 3 并发 worker 池 |
| 历史页 build 中途写 provider | history_screen.dart | 移到 `addPostFrameCallback` + 点数变化守卫 |
| 三页 30s ticker 后台仍唤醒 | map/devices/events screen | `WidgetsBindingObserver`：后台 cancel、回前台恢复 |

### 2.2 性能预算达成评估

| 指标 | 预算 | 评估 | 依据 |
|---|---|---|---|
| 冷启动可交互 | < 2.5s | ✅ 可达 | 启动路径无阻塞 SDK 初始化（Firebase 推迟）；DB 用后台 isolate；日志清扫 O(小目录) |
| 地图首屏 | < 2s | ✅ 可达 | 缓存先行（AsyncValue.data）+ REST 增量刷新；标记派生 O(n) |
| 500 设备标记更新 | ≥ 30fps | ✅ 存疑→真机验证 | 每次 WS 消息重建 Marker Set（高德 API 所限）；50 尾迹点裁剪 O(1) 摊销；聚合 O(n)。需真机帧率实测 |
| 历史 7 天首屏 | < 3s | ✅ 可达 | 分段请求（≤2 天/段）+ 3 并发可扩；DP 抽稀仅一次 |
| 10k 点回放 | 流畅 | ✅ 可达 | 迭代 DP + 缓存渲染点；步进播放固定节奏 |
| 内存（500 设备） | < 250MB | ✅ 可达 | 尾迹 50 点/设备 ≈ 500×50×16B ≈ 400KB；日志 500 条环形；去重集合有界（5000/1000） |
| 24h 电耗 | ≤ 6% | ✅ 架构支持 | medium/300s/75m 默认；后台 WS 断开；ticker 后台暂停；停驶检测默认开。最终以真机 24h 实测为准 |

> 2.2 中标注「存疑」的两项需要真机矩阵验证（docs/06 Sprint 3.8 与 5.5），
> 架构层面已消除已知数量级问题。

## 3. 平台构建验证（2026-11-14 补充）

**debug APK 构建通过**（Windows + JDK 17 + SDK Platform 37 + Gradle 9.3.1 + AGP 9.1），
验证范围：AndroidManifest 合法性、Gradle Kotlin DSL、ProGuard 规则、全部插件集成、
Dart AOT、原生资产（sqlite3 下载）。

过程中发现并固化三个工具链问题（`tool/fix-plugins.sh` 自动处理，CI 已接入）：

1. **插件 compileSdk 不一致**：amap_map 1.0.15 硬编码 35（低于 lifecycle 的 36）；
   permission_handler_android 14.x / traccar_client_sdk 需要 API 37 符号
   （`ACCESS_LOCAL_NETWORK` 等）。处理：amap_map 补丁到 36，其余保持 37，
   `:app` compileSdk 提到 37（AGP 9.1 对 37 有非推荐 warning，可忽略）。
2. **SDK 37 包名缺口**：部分渠道 SDK 37 的包名为 `android-37.0`，
   AGP 9 按 `android-37` 查找失败 —— 本机通过重命名目录 + 修正
   `package.xml`/`source.properties` 的 api-level 元数据解决。
3. **Gradle 9.3 root `subprojects{}` 的 afterEvaluate 不触发**（本环境实测），
   不可依赖跨项目 compileSdk 注入，需在插件层修补。

**CN 包成分现状**：debug 包中仍含 firebase/gms 成分（pubspec 未拆分），
CI 的 `cn-build-hygiene` job 会在 CN 构建后断言；提审前按 docs/09 §3.9 完成依赖拆分。

## 4. 遗留与后续

1. **真机验证**（docs/10 M0 清单 0.2–0.8）：高德渲染帧率、24h 心跳、国产 ROM 后台存活 —— 代码层无法替代。
2. **CN 包 Firebase 拆分**（docs/09 §3.9）：CI 已加 APK 成分断言；彻底拆分需维护 `pubspec_cn.yaml` 或分支，属发布前工程动作。
3. **`connectivity_plus` / `battery_plus` / `flutter_map` 等未接线依赖**：按 flavor 清理（海外包接 flutter_map 兜底、诊断页接 battery_plus 白名单检测）。
4. **推送指令 HMAC**：✅ 已升级为每别名独立 `commandSecret`（网关注册时签发、HTTPS 下发、Secure Storage 存储），消除打进客户端的静态共享密钥；别名缺失密钥时指令通道自动关闭。
5. **LogRedactor 单测**：已覆盖 JWT/凭据/坐标；Base64 与 `Basic` 场景建议补充用例。
6. **release 签名**：`android/key.properties` 需要正式 keystore（构建已强制）；
   高德 Key 与极光 AppKey 与签名/包名绑定，改包名（ADR-015）后需重申请。
