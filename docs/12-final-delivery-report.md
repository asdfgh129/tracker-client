# 12 · 最终交付报告（zcode 分支）

> 交付日期：2026-11-14 · 分支：`zcode` · 提交：`1f0e1c8` · 版本：**v0.2.0+1**
>
> 本报告是 TrackerOne MVP 交付的权威总结：功能实现、审计整改、验证结果与
> 外部依赖清单。安全与性能细节见 [docs/11](11-security-performance-audit.md)，
> 变更记录见 [CHANGELOG](../CHANGELOG.md)。

## 1. 交付概览

| 项 | 值 |
|---|---|
| 分支 | `zcode`（基于 master 新建，已推送 origin） |
| 提交规模 | 136 文件，+18,377 / −482 行 |
| 代码规模 | lib/ 80 个 Dart 文件，23,622 行 |
| i18n | en/zh 各 395 条消息键，UI 零硬编码 |
| 验证 | analyze 0 issues（strict 模式）· 58/58 单测 · 平台自检全过 · **debug APK 构建通过** |

交付范围：**docs/01 PRD 全部 P0 需求**（AUTH/TRK/MAP/HIS/EVT/DEV/SET/CN 八域），
对齐 docs/00 章程 MVP 定义；P1（OIDC、围栏编辑、报表汇总、离线瓦片、小组件等）
按排期留待 v1.1（docs/06 §6）。

## 2. 新增功能明细（对照 PRD 需求编号）

> 本章为 0.2.0 交付时点的 PRD 对照表。全量两端功能清单（客户端 12 业务域 +
> 服务端模块 + 依赖映射，含 0.4.x 增量）见
> [docs/18-feature-inventory.md](18-feature-inventory.md)。

### 2.1 服务器与账号（AUTH）

| ID | 实现 | 代码入口 |
|---|---|---|
| AUTH-01/02 | 档案 CRUD；地址自动推导（`:8082`→`:5055`、反代路径、明文拦截） | `core/network/server_profile.dart` |
| AUTH-03 | 二维码导入：URL（Traccar Client 格式）/JSON/深链三格式；不自动继承信任（M-7） | 同上 `parseImport` |
| AUTH-04/05/06 | 密码登录→Cookie→换长期 Token；Token 直登；Secure Storage 持久化 | `features/auth/application/session_controller.dart` |
| AUTH-07 | 生物识别锁（M-8：锁住 API 访问面而非仅 UI） | 同上 + `app_lock_screen.dart` |
| AUTH-09 | 多档案存储与切换（切换清会话缓存） | `features/server/application/server_profile_controller.dart` |
| AUTH-10 | 登出撤销远端 Token + 本地全量清理 | `session_controller.dart logout()` |
| AUTH-11 | `GET /api/server` 能力探测 + 测试连接五态（成功/401/TLS/超时/非 Traccar） | `server_profile_controller.dart probe()` |

### 2.2 本机跟踪（TRK）

| ID | 实现 | 代码入口 |
|---|---|---|
| TRK-01/02 | 8 位 uniqueId 生成/编辑；绑定（查→建→403 降级提示） | `features/tracking/application/self_device_binder.dart` |
| TRK-03~05 | 开始/停止/单次/SOS（alarm=sos），启动前权限预检 | `features/tracking/application/tracking_controller.dart` |
| TRK-06/07 | 全配置项 + 热更新（applyConfig 无需重启） | `tracking_profile.dart` |
| TRK-08 | 预设：步行/驾车/资产/高频/省电（docs/05 §4.2 数值） | 同上 |
| TRK-09/10 | 状态机六态 + 最后上报/队列/电量展示 | `tracking_controller.dart` + `tracking_screen.dart` |
| TRK-11/12 | 快捷操作（定位/SOS）+ 常驻通知（SDK 通知文案带服务器域名） | `tracking_screen.dart` |
| TRK-14/15 | 开机恢复（SDK 内置）+ 厂商省电引导 | `core/location/vendor_hints.dart` |
| TRK-16 | 引擎日志查看/导出 | `diagnostics_screen.dart` |

### 2.3 实时地图（MAP）与设备（DEV）

| ID | 实现 | 代码入口 |
|---|---|---|
| MAP-01/07 | 设备列表（在线优先排序、电量/速度/最后更新）、搜索筛选 | `features/devices/presentation/devices_screen.dart` |
| MAP-02~06 | 标记/方向/状态色、尾迹（50 点缓冲）、网格聚合（>50 触发）、跟随模式（拖动退出） | `features/map/application/map_controller.dart` |
| MAP-03 | REST 快照 + WS 增量 + drift 缓存三路合并（缓存先行，冷启动不白屏） | `features/devices/application/devices_controller.dart` |
| MAP-08/12 | 设备底部卡片（历史/跟随/指令入口）+ 设备详情页 | `map_screen.dart` + `device_detail_screen.dart` |
| MAP-09 | 供应商抽象（`TrackerMapView` 唯一入口 + 隐私同意门） | `core/map/tracker_map_view.dart` |
| DEV-01 | 设备详情（状态/速度/海拔/电量/uniqueId） | `device_detail_screen.dart` |
| DEV-04/05 | 指令发送（200/202 区分、按协议过滤类型、5 秒内 UI 反馈） | `features/commands/application/command_center.dart` |
| DEV-06 | 本机指令接收执行（验签后）+ factoryReset 二次确认 | 同上 |

### 2.4 历史与报表（HIS）

| ID | 实现 | 代码入口 |
|---|---|---|
| HIS-01 | 今日/昨日/7 天/自定义（自定义校验起止） | `features/history/application/history_controller.dart` |
| HIS-02 | 回放：进度条 + 1/2/4/8× 倍速，地图游标同步 | `history_screen.dart` + PlaybackController |
| HIS-03 | 停留检测（速度 0.6m/s + 60m 半径 + 簇心浮动，≥3 分钟） | `features/history/application/track_math.dart` |
| HIS-04 | 速度/海拔/电量曲线（CustomPainter） | `history_screen.dart _Charts` |
| HIS-06 | GPX/KML/CSV 导出（WGS-84、XML 转义、文件名清洗、系统分享） | `features/history/application/track_export.dart` |
| HIS-08 | 事件时间轴（Tab 视图） | `history_screen.dart _HistoryEvents` |

### 2.5 事件与推送（EVT）

| ID | 实现 | 代码入口 |
|---|---|---|
| EVT-01/02 | 30 天缓存列表、四段筛选、未读点、左滑已读 | `features/events/` |
| EVT-03 | 推送三通道归一化（JPush extras / FCM data / WS events） | `core/push/` |
| EVT-04 | 点击直达 `/event/:id`；未登录缓存意图、登录后消费 | `core/push/push_router.dart` |
| EVT-06 | WS 实时进料 + 前台横幅（不弹系统通知） | `devices_controller.dart` + PushRouter |

### 2.6 设置运维（SET）与诊断

| ID | 实现 | 代码入口 |
|---|---|---|
| SET-01/02 | 公英制、主题三态、语言（system/en/zh） | `features/settings/application/settings_controller.dart` |
| SET-03 | 隐私与权限页（清单/SDK 列表/撤回同意/数据删除） | `settings_screen.dart` |
| SET-04 | 诊断页：结论引擎（权限→服务→定位→上报→实时五步）、权限矩阵、队列、服务器可达、时钟偏差、日志导出 | `features/diagnostics/` |
| SET-05 | 匿名统计开关（真实生效，同意门控） | `settings_controller.dart` |
| SET-06 | 关于页：版本/备案号占位/审图号占位/隐私政策/许可 | `about_screen.dart` |
| CN-05/06/08/09 | 隐私同意门、后台定位单独同意、备案/审图号占位、数据删除+撤回同意 | 各对应文件 |

### 2.7 推送与深链

- 别名注册：`POST /v1/alias-salt`（网关校验 Traccar 会话后签发随机盐）→ `POST /v1/aliases`；
  盐值存 Secure Storage（`push.aliasSalt.<serverId>`）；未取得盐值则跳过注册（防枚举）。
- PushRouter：事件→导航、指令→CommandCenter、未登录缓存、`consumePending()` 放行。
- 通道：JPush（CN）/FCM（海外）/Noop 三实现，`--dart-define` 选择。
- 深链：`trackerone://event/<id>`、`trackerone://server`；Android Manifest + iOS CFBundleURLTypes；
  Flutter 自动深链已关闭（JPush 厂商通道白屏规避）。

## 3. 基础设施新增

| 层 | 内容 |
|---|---|
| 网络 | `TraccarApi`（docs/04 全量 REST）、Auth/Retry(仅 GET)/Error 映射/脱敏日志四拦截器、`SocketClient`（指数退避 ±20% 抖动、快照语义、位置与事件幂等、解析容错不断连、suspend/resume）、自签名证书策略（条件导入） |
| 存储 | drift 六表（档案/设备/位置/事件/队列/跟踪快照）+ 索引 + 保留策略（位置 7 天/事件 30 天）、SecureStore（Keystore/Keychain）、命名空间 Prefs、DataEraser（日志+导出文件擦除） |
| 可观测 | AppLog（500 条环形 + LogRedactor 脱敏）、FileLogSink（10MB 轮转/7 天）、CrashReporter（同意门控，H-5） |
| 领域 | Device/Position/DeviceEvent/Account 实体、AppFailure 密封类（10 类） |
| 工具 | Clock 抽象 + Throttle |
| i18n | en/zh 各 395 键 |

## 4. 平台工程

- `android/`、`ios/` 平台工程已生成并完成全部原生配置：
  15 项权限、前台服务 location 类型、`allowNativeHeapPointerTagging=false`、
  `allowBackup=false` + `dataExtractionRules`（备份全排除）、
  JPush manifestPlaceholder、深链 scheme、desugaring、ProGuard 保留规则、
  iOS Info.plist 五项文案 + UIBackgroundModes + BGTask + URL Scheme。
- **4 个 tool 脚本**：`bootstrap.sh`（重生成平台工程）、`verify.sh`（一键验证）、
  `configure-platform.sh`（断言式自检，CI 运行）、`fix-plugins.sh`（插件 compileSdk 对齐）。
- **CI**（`.github/workflows/ci.yml`）：最小权限 + Action 锁 SHA；
  verify job（pub get→gen-l10n→build_runner→analyze→test→插件对齐→平台自检）+
  cn-build-hygiene job（CN 变体构建 + APK 成分断言）。

## 5. 服务端交付

| 交付物 | 说明 |
|---|---|
| `server/traccar-plugin/.../NotificatorWebhook.java` | Traccar 6.16 事件 webhook（HMAC、HTTPS 强制、secret fail-closed、payload 最小化、日志截断） |
| `server/gateway/gateway.js` | 零依赖 Node.js 推送网关参考实现：HMAC 常量时间校验、event.id 幂等（24h）、限流（60/min）、盐值签发与归属校验、模板渲染、极光 REST 下行、指令 HMAC 签名、容量上限 |
| `server/gateway/test-gateway.sh` | 联调脚本（健康检查/签名/幂等/401/归属校验） |
| `server/README.md` | 补丁安装、网关契约（含安全基线）、traccar.xml 配置、环境变量清单 |

## 6. 验证结果

| 验证项 | 结果 | 备注 |
|---|---|---|
| `flutter analyze` | **0 issues** | strict-casts / strict-inference / strict-raw-types 全开 |
| `flutter test` | **58/58 通过** | 坐标/URL 推导/QR 解析/WS 解析与幂等/抽稀/停留/里程/GPX-KML-CSV/脱敏/诊断引擎/预设/uniqueId |
| 平台自检 `configure-platform.sh` | Android/iOS 全 ✓ | 合规红线（多余敏感权限）为零 |
| **APK 构建** | **✓ app-debug.apk**（258MB debug 全 ABI） | JDK 17 + SDK 37 + Gradle 9.3.1 + AGP 9.1 真实工具链 |
| CN 包成分 | debug 包仍含 firebase（依赖未拆分） | CI 断言就位，提审前按 docs/09 §3.9 拆分 |

工具链沉淀（`tool/fix-plugins.sh` 处理，CI 已接入，详见 docs/11 §3）：
amap_map compileSdk 35→36 补丁；SDK 37 包名缺口（android-37.0→android-37 元数据修正）；
Gradle 9.3 root `subprojects{}` 的 afterEvaluate 不触发（不可依赖跨项目注入）。

## 7. 安全审计结论（29 项全处置）

MASVS-L1 首轮审计：2C + 8H + 11M + 8L。全部处置：

- **已整改（代码层验证）**：网关默认令牌删除（C-1）、iOS 相机文案（H-1）、
  明文独立确认（H-3）、SDK 同意门控（H-5）、删除权完整实现（H-6）、
  release 签名强制（H-7）、指令验签 fail-closed（H-4）、备份排除（M-1）、
  脱敏加固（M-3）、debugPrint 清零（M-4）、文件名清洗（M-5）、
  导入信任显式化（M-7）、生物锁真门禁（M-8）、CI 加固（M-9）、
  插件强化（M-10）、intl 锁版本（L-1）、gitignore 通配（L-7）等。
- **代码就绪、部署时生效**：C-2/H-2 盐值别名与归属校验（网关部署后生效）；
  H-8 备案号/隐私政策 URL（外部审批）。

完整清单与证据行号见 [docs/11](11-security-performance-audit.md)。

## 8. 性能审计结论（6 项整改）

地图渲染 provider 去写副作用、历史抽稀缓存一次、DP 算法迭代化（防 10k 点栈溢出）、
事件表双索引、事件补拉 3 并发、三页 ticker 后台暂停。
预算对照与量化分析见 docs/11 §2.2；500 设备帧率与 24h 电耗需真机实测。

## 9. 外部依赖清单（代码已就绪，待补真实值）

| # | 项 | 占位方式 | 补上动作 |
|---|---|---|---|
| 1 | 高德 Android/iOS Key | `--dart-define=AMAP_ANDROID_KEY / AMAP_IOS_KEY`（缺省显示占位卡片，不初始化 SDK） | 高德控制台申请（绑定包名+SHA1）后传入 |
| 2 | 极光 AppKey | gradle `-PJPUSH_APPKEY` 或 gradle.properties | 极光后台申请；厂商通道需企业资质 |
| 3 | 推送网关部署 | `server/gateway/gateway.js` 参考实现 | 服务器部署，配置 5 个环境变量（fail-closed） |
| 4 | 指令签名密钥 | 每别名独立 `commandSecret`（网关注册时签发，Secure Storage 存储；未配=指令通道关闭） | 无需人工配置；网关与 App 需同版本上线 |
| 5 | APP 备案号 | `--dart-define=APP_FILING_NUMBER`（关于页显示"审批中"） | 备案通过后注入 |
| 6 | 地图审图号 | `--dart-define=MAP_APPROVAL_NUMBER` | 高德 Key 审批后获取 |
| 7 | 隐私政策 URL | `Brand.privacyUrl`（example.com 占位） | 上线前替换为真实地址 |
| 8 | 正式签名 | `android/key.properties`（缺失时 release 构建失败） | 生成 keystore 并填入 |
| 9 | 包名 | `com.trackerone.app`（ADR-015 已定稿） | ✅ 已完成；高德 Android Key 与极光 AppKey 已内置（docs/15） |
| 10 | 真机矩阵验证 | docs/10 M0 清单 0.2–0.8 | 高德帧率、24h 心跳、国产 ROM 后台存活（代码无法替代） |

## 10. 已知限制与后续建议

1. **CN 包 Firebase 拆分**（docs/09 §3.9）：CI 断言就位；彻底拆分需维护
   `pubspec_cn.yaml` 或独立分支，属发布前工程动作。
2. **未接线依赖**：`connectivity_plus` / `battery_plus` / `flutter_map` /
   `latlong2` / `flutter_local_notifications` 已清理（v0.5.2）；后续如接海外
   瓦片方案再按需引入。
3. **网关存储**：内存 Map 仅适用单实例；多实例换 Redis（键结构见代码注释）。
4. **LogRedactor 用例**：建议补 Base64 与 `Basic` 场景单测。
5. **单元测试覆盖**：UI 层（Widget 测试）与集成测试（`integration_test/`）为
   v1.1 工作（docs/07 §2）。

## 11. 提交记录

```
1f0e1c8 feat: TrackerOne v0.2.0 MVP 全量实现 + 安全/性能审计整改
d396b0f init repostry
```

分支 `zcode` → `origin/zcode`（2026-11-14 推送）。
