# TrackerOne

把 **Traccar Client**（本机后台上报）与 **Traccar Manager**（设备查看与管理）合二为一的 Flutter 移动应用，兼容 Traccar 6.x 服务端。

> 工作代号 **TrackerOne**，包名 / 品牌 / 默认服务器均为占位值，可通过 `lib/core/config/brand.dart` 统一替换。

## 项目状态

| 阶段 | 状态 |
|---|---|
| 产品与技术规划 | ✅ 完成（见 `docs/`） |
| 中国大陆方案（地图/推送/备案） | ✅ 已定（见 `docs/09`） |
| 工程骨架 + 平台工程 | ✅ android/ ios/ 已生成并配置 |
| 核心抽象（坐标系 / 地图 / 推送） | ✅ 编译验证通过（Flutter 3.47.9） |
| **MVP 开发（P0 全量）** | ✅ 已实现（见 CHANGELOG 0.2.0） |
| **好友体系（5056 消息通道）** | ✅ 已实现（见 CHANGELOG 0.3.0；服务端 tracker-server CN-1.1） |
| **发布工程 + opencode 线能力合并** | ✅ 包名/Key 定稿、每别名指令密钥、指令发件箱、缩放聚合、网关韧性（见 CHANGELOG 0.4.0） |
| 单元测试 | ✅ 130 用例全绿；`flutter analyze` 0 issues |
| 推送网关参考实现 | ✅ `server/`（零依赖 Node.js 网关；正式 NotificatorWebhook 在 tracker-server） |
| 安全审计（MASVS-L1） | ✅ 首轮审计 + 阻断项整改（见 `docs/11-security-performance-audit.md`） |
| 待办（外部依赖） | ⬜ 高德/极光 Key、备案号、隐私政策 URL（`--dart-define` 占位） |

> 首发市场为**中国大陆**。当前地图按高德实施，推送按极光 + 厂商通道实施；
> 详细依据见 [docs/09-china-launch.md](docs/09-china-launch.md)。

## 为什么不是简单合并

| 维度 | Traccar Client | Traccar Manager | TrackerOne |
|---|---|---|---|
| 定位 | 本机位置上报 | 查看/管理设备 | 两者合一 |
| 界面 | 原生 5 页 | WebView 套壳 | 原生地图优先 |
| 服务器配置 | 只有上报地址 | 只有 Web 地址 | 服务器档案（API + 上报） |
| 实时性 | 无 | 依赖 Web 前端 | REST + WebSocket 原生订阅 |
| 历史轨迹 | 无 | 依赖 Web 前端 | 原生回放 + 图表 + 导出 |
| 推送 | 远程指令 | Web 事件转发 | 事件 + 指令统一路由 |
| 离线 | SDK 队列 | 无 | 本地缓存 + 队列 + 重试 |
| 权限 | 后台定位 | 前台定位 | 分阶段申请 + 健康检查 |
| 国际化 | 35 语言 | 无 | 统一 ARB，继承 35 语言 |

## 核心能力（MVP）

- **本机实时上报**：后台定位、断网缓存、开机恢复、省电策略、快捷开关、SOS。
- **多设备实时地图**：设备列表、状态、聚合、跟随、轨迹尾迹、WebSocket 实时更新。
- **好友互见位置**：仅互为好友可互见；好友位置实时广播、按需定位请求（对方同意）、
  申请/同意/删除全流程、离线邀请经极光唤醒（5056 消息通道）。
- **历史与报表**：行程、停留、路线回放、速度/海拔曲线、GPX/KML/CSV 导出。
- **事件与推送**：围栏/告警推送、点击直达、应用内事件流、免打扰。
- **远程指令**：单次定位、开始/停止上报、恢复出厂设置（经推送网关下发到离线手机）。
- **多服务器**：自建/托管服务器档案、二维码导入、Token 登录、TOTP 两步验证、
  **OIDC 企业登录（SSO，0.5.0）**、生物识别锁。
- **可运维**：诊断页（权限、队列、最后上报、日志导出）、崩溃上报、通知规则自助管理。

## 技术栈

| 层 | 选型 |
|---|---|
| 框架 | Flutter 3.x / Dart 3.x（Android 24+，iOS 15+） |
| 状态管理 | Riverpod |
| 路由 | go_router |
| 网络 | dio + `web_socket_channel` |
| 本地存储 | drift（SQLite）/ flutter_secure_storage / shared_preferences |
| 定位引擎 | `traccar_client_sdk`（Apache-2.0，可替换） |
| 地图 | 高德 `amap_map`（中国大陆，GCJ-02）；`flutter_map` 保留海外/兜底 |
| 推送 | 极光 JPush + 厂商通道 + 自建网关；FCM 仅海外/开发 |
| 坐标 | 数据层 WGS-84，仅渲染层转 GCJ-02 |
| 可观测 | 默认 `NoopCrashReporter`；国内 Bugly（0.5.1）、海外 Crashlytics，同意门控 |
| 后端 | tracker-server（Traccar-CN fork：REST + WebSocket + 5056 消息通道；NotificatorWebhook / 指令下行 / 邀请唤醒内置） |
| 合规 | APP 备案、域名 ICP、隐私同意流、SDK 清单、审图号 |

## 目录结构

```
tracker-client/
├── android/  ios/            # 平台工程（已生成并配置，见 tool/configure-platform.sh）
├── docs/                     # 开发文档（先读 00、01、03、09；11 为审计报告）
├── lib/
│   ├── app/                  # App 壳、路由守卫、Shell、通用组件
│   ├── core/
│   │   ├── config/           # BuildConfig / 品牌（含备案号占位）
│   │   ├── location/         # 权限服务、厂商引导
│   │   ├── map/              # 坐标系、地图抽象、高德适配、隐私同意门
│   │   ├── network/          # REST / WebSocket / 5056 消息客户端 / 拦截器 / 证书策略
│   │   ├── observability/    # 日志脱敏、文件 sink、崩溃上报（同意门控）
│   │   ├── push/             # PushGateway、极光、FCM、网关客户端、深链路由
│   │   ├── storage/          # drift 七表、SecureStore、Prefs、数据擦除
│   │   ├── tracking/         # TrackingEngine 与 SDK 适配
│   │   └── utils/            # Clock 等基础工具
│   ├── domain/               # 实体 + AppFailure 错误模型
│   └── features/             # 12 个业务域（application 控制器 + presentation 页面）
├── server/
│   ├── gateway/              # 推送网关参考实现（零依赖 Node.js）+ 联调脚本
│   └── traccar-plugin/       # NotificatorWebhook 参考实现（正式版在 tracker-server）
├── test/                     # 单元测试（130 用例）
├── tool/
│   ├── bootstrap.sh          # 重新生成平台工程（FORCE）
│   ├── verify.sh             # pub get / 代码生成 / analyze / test
│   ├── configure-platform.sh # 平台配置自检（CI 同步运行）
│   └── fix-plugins.sh        # 插件 compileSdk 对齐（pub get 后运行）
├── .github/workflows/ci.yml  # CI：analyze/test/平台自检/CN 成分断言
├── pubspec.yaml
└── analysis_options.yaml
```

## 快速开始

Flutter 安装完成后，先生成平台工程，再拉依赖：

```bash
cd trackerone

# 1. 生成 android/ 与 ios/（只复制平台目录，不覆盖 lib/ 与 docs/）
tool/bootstrap.sh

# 2. 依赖与代码生成
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter gen-l10n

# 3. 编译与测试（等价于 tool/verify.sh）
flutter analyze
flutter test
# 4. 运行（中国大陆配置）
flutter run \
  --dart-define=API_BASE_URL=https://track.example.com \
  --dart-define=MAP_PROVIDER=amap \
  --dart-define=AMAP_ANDROID_KEY=$AMAP_ANDROID_KEY \
  --dart-define=AMAP_IOS_KEY=$AMAP_IOS_KEY \
  --dart-define=PUSH_PROVIDER=jpush \
  --dart-define=JPUSH_APP_KEY=$JPUSH_APP_KEY
```

平台工程生成后，按 [`docs/10-setup-runbook.md`](docs/10-setup-runbook.md) 配置：
权限、`allowNativeHeapPointerTagging=false`、iOS Background Modes、极光厂商通道。

> 未配置 Key 时用 `MAP_PROVIDER=none` / `PUSH_PROVIDER=none`，应用仍可启动，
> 只是地图显示占位、推送退化为应用内事件。

## 文档索引

| 文档 | 内容 |
|---|---|
| [00-project-charter.md](docs/00-project-charter.md) | 背景、愿景、目标、范围、成功指标 |
| [01-prd.md](docs/01-prd.md) | 功能需求、优先级、验收标准 |
| [02-ux-spec.md](docs/02-ux-spec.md) | 信息架构、页面、状态、设计规范 |
| [03-architecture.md](docs/03-architecture.md) | 分层架构、模块、数据流、时序 |
| [04-api-integration.md](docs/04-api-integration.md) | Traccar REST / WebSocket / 推送 / 上报协议 |
| [05-tracking-engine.md](docs/05-tracking-engine.md) | 后台定位方案、权限、省电、可靠性、中国合规 |
| [06-roadmap.md](docs/06-roadmap.md) | 里程碑、任务拆解、排期、DoD |
| [07-quality-release.md](docs/07-quality-release.md) | 测试、CI/CD、发布、合规 |
| [08-decisions-risks.md](docs/08-decisions-risks.md) | ADR、风险登记、待决问题 |
| [09-china-launch.md](docs/09-china-launch.md) | 中国大陆地图/推送/备案/商店落地方案 |
| [10-setup-runbook.md](docs/10-setup-runbook.md) | 环境搭建、平台工程、M0 验收手册 |
| [11-security-performance-audit.md](docs/11-security-performance-audit.md) | 安全（MASVS-L1）与性能审计、整改记录、工具链问题 |
| [12-final-delivery-report.md](docs/12-final-delivery-report.md) | 最终交付报告：功能明细、验证结果、外部依赖清单 |
| [17-client-server-alignment-audit.md](docs/17-client-server-alignment-audit.md) | 客户端↔服务端协议对齐审计：六链路矩阵、差异清单、整改记录 |
| [18-feature-inventory.md](docs/18-feature-inventory.md) | 两端实现功能详细清单：客户端 12 业务域 + 服务端模块 + 依赖映射 |
| [server/README.md](server/README.md) | Traccar webhook 补丁、推送网关契约（含安全基线）、联调 |

## 许可证与商标

本项目的架构与接口设计参考 Apache-2.0 的 Traccar 生态项目，但不包含其品牌资源。发布前请确认：

- `Traccar` 名称与图标的使用权限；
- 高德地图的授权、配额与测绘合规（展示审图号）；
- 后台定位相关的应用商店政策、隐私政策与 APP 备案。
