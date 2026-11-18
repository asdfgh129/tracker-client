import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/build_config.dart';
import '../../../core/map/map_privacy_consent.dart';
import '../../../core/observability/crash_reporter.dart';
import '../../../core/observability/logger.dart';
import '../../../core/storage/secure_store.dart';

import '../../../core/storage/preferences.dart';
import '../../../core/providers.dart';

/// 使用模式（PRD §1：跟踪本机 / 查看设备 / 两者都要）。
enum UsageMode { track, view, both }

/// 单位制（SET-01）。
enum UnitSystem { metric, imperial }

/// 底图样式（MAP-11）。
enum MapStylePref { standard, satellite, night }

/// 应用设置状态。全部为非敏感配置，存 SharedPreferences。
class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.localeLanguageCode,
    this.units = UnitSystem.metric,
    this.mode = UsageMode.both,
    this.mapStyle = MapStylePref.standard,
    this.mapTrail = true,
    this.mapCluster = true,
    this.analyticsEnabled = false,
    this.privacyAgreed = false,
    this.privacyPolicyVersion = 0,
    this.notificationsEnabled = true,
  });

  final ThemeMode themeMode;

  /// null = 跟随系统；'en' / 'zh'。
  final String? localeLanguageCode;
  final UnitSystem units;
  final UsageMode mode;
  final MapStylePref mapStyle;
  final bool mapTrail;
  final bool mapCluster;
  final bool analyticsEnabled;
  final bool privacyAgreed;

  /// 已同意的隐私政策版本号（0 = 未按版本同意过）。
  final int privacyPolicyVersion;

  /// 隐私门是否放行：同意过**且**同意的是当前版本的政策。
  /// 旧版本同意在政策升级后失效，需重新确认（CN-05）。
  bool get privacyGatePassed =>
      privacyAgreed &&
      privacyPolicyVersion >= SettingsController.privacyPolicyCurrentVersion;

  final bool notificationsEnabled;

  AppSettings copyWith({
    ThemeMode? themeMode,
    String? localeLanguageCode,
    bool clearLocale = false,
    UnitSystem? units,
    UsageMode? mode,
    MapStylePref? mapStyle,
    bool? mapTrail,
    bool? mapCluster,
    bool? analyticsEnabled,
    bool? privacyAgreed,
    int? privacyPolicyVersion,
    bool? notificationsEnabled,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      localeLanguageCode:
          clearLocale ? null : (localeLanguageCode ?? this.localeLanguageCode),
      units: units ?? this.units,
      mode: mode ?? this.mode,
      mapStyle: mapStyle ?? this.mapStyle,
      mapTrail: mapTrail ?? this.mapTrail,
      mapCluster: mapCluster ?? this.mapCluster,
      analyticsEnabled: analyticsEnabled ?? this.analyticsEnabled,
      privacyAgreed: privacyAgreed ?? this.privacyAgreed,
      privacyPolicyVersion: privacyPolicyVersion ?? this.privacyPolicyVersion,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
    );
  }
}

/// 设置控制器。
class SettingsController extends Notifier<AppSettings> {
  /// 当前隐私政策版本。条款发生实质变更时递增，
  /// 所有旧版本同意自动失效，用户重新过隐私门（CN-05，对齐 ADR-014）。
  static const int privacyPolicyCurrentVersion = 1;

  @override
  AppSettings build() {
    final prefs = ref.watch(prefsProvider);
    return AppSettings(
      themeMode: _themeFrom(prefs.getString(PrefKeys.themeMode)),
      localeLanguageCode: _localeFrom(prefs.getString(PrefKeys.locale)),
      units: prefs.getString(PrefKeys.units) == 'imperial'
          ? UnitSystem.imperial
          : UnitSystem.metric,
      mode: _modeFrom(prefs.getString(PrefKeys.usageMode)),
      mapStyle: _styleFrom(prefs.getString(PrefKeys.mapStyle)),
      mapTrail: prefs.getBool(PrefKeys.mapTrailEnabled) ?? true,
      mapCluster: prefs.getBool(PrefKeys.mapClusteringEnabled) ?? true,
      analyticsEnabled: prefs.getBool(PrefKeys.analyticsEnabled) ?? false,
      privacyAgreed: prefs.getBool(PrefKeys.privacyAgreed) ?? false,
      privacyPolicyVersion:
          prefs.getInt(PrefKeys.privacyPolicyVersion) ?? 0,
      notificationsEnabled: prefs.getBool(PrefKeys.notificationsEnabled) ?? true,
    );
  }

  MapStylePref _styleFrom(String? value) => switch (value) {
        'satellite' => MapStylePref.satellite,
        'night' => MapStylePref.night,
        _ => MapStylePref.standard,
      };

  ThemeMode _themeFrom(String? value) => switch (value) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  String? _localeFrom(String? value) =>
      value == null || value.isEmpty ? null : value;

  UsageMode _modeFrom(String? value) => switch (value) {
        'track' => UsageMode.track,
        'view' => UsageMode.view,
        _ => UsageMode.both,
      };

  Future<void> setThemeMode(ThemeMode mode) async {
    await ref.read(prefsProvider).setString(
          PrefKeys.themeMode,
          switch (mode) {
            ThemeMode.light => 'light',
            ThemeMode.dark => 'dark',
            ThemeMode.system => 'system',
          },
        );
    state = state.copyWith(themeMode: mode);
  }

  Future<void> setLocale(String? languageCode) async {
    await ref
        .read(prefsProvider)
        .setString(PrefKeys.locale, languageCode ?? '');
    state = state.copyWith(localeLanguageCode: languageCode, clearLocale: languageCode == null);
  }

  Future<void> setUnits(UnitSystem units) async {
    await ref.read(prefsProvider).setString(
          PrefKeys.units,
          units == UnitSystem.imperial ? 'imperial' : 'metric',
        );
    state = state.copyWith(units: units);
  }

  Future<void> setMode(UsageMode mode) async {
    await ref.read(prefsProvider).setString(
          PrefKeys.usageMode,
          switch (mode) {
            UsageMode.track => 'track',
            UsageMode.view => 'view',
            UsageMode.both => 'both',
          },
        );
    state = state.copyWith(mode: mode);
  }

  Future<void> setMapStyle(MapStylePref style) async {
    await ref.read(prefsProvider).setString(
          PrefKeys.mapStyle,
          switch (style) {
            MapStylePref.standard => 'standard',
            MapStylePref.satellite => 'satellite',
            MapStylePref.night => 'night',
          },
        );
    state = state.copyWith(mapStyle: style);
  }

  Future<void> setMapTrail(bool value) async {
    await ref.read(prefsProvider).setBool(PrefKeys.mapTrailEnabled, value);
    state = state.copyWith(mapTrail: value);
  }

  Future<void> setMapCluster(bool value) async {
    await ref.read(prefsProvider).setBool(PrefKeys.mapClusteringEnabled, value);
    state = state.copyWith(mapCluster: value);
  }

  /// H-5：统计开关必须真正生效（之前只写偏好，SDK 仍默认采集）。
  Future<void> setAnalyticsEnabled(bool value) async {
    state = state.copyWith(analyticsEnabled: value);
    await _syncAnalyticsCollection(enabled: value);
  }

  Future<void> setNotificationsEnabled(bool value) async {
    await ref
        .read(prefsProvider)
        .setBool(PrefKeys.notificationsEnabled, value);
    state = state.copyWith(notificationsEnabled: value);
  }

  /// 隐私同意（CN-05）。
  ///
  /// H-5：同意是第三方 SDK 初始化的**唯一触发点** ——
  /// 崩溃上报（海外包）与匿名统计都在这里才开始采集，
  /// 未同意前不会初始化任何第三方 SDK（商店隐私检测会抓包验证）。
  Future<void> agreePrivacy() async {
    final prefs = ref.read(prefsProvider);
    await prefs.setBool(PrefKeys.privacyAgreed, true);
    await prefs.setInt(
      PrefKeys.privacyPolicyVersion,
      privacyPolicyCurrentVersion,
    );
    await prefs.setString(
      PrefKeys.privacyAgreedAt,
      DateTime.now().toUtc().toIso8601String(),
    );
    state = state.copyWith(
      privacyAgreed: true,
      privacyPolicyVersion: privacyPolicyCurrentVersion,
    );

    // 崩溃上报：crasher 的 SDK 初始化推迟到此处。
    try {
      await ref.read(crashReporterProvider).initialize();
    } on Object {
      // 初始化失败不影响同意状态与业务功能。
    }

    // 匿名统计：仅当用户开关打开且非中国大陆包时启用。
    await _syncAnalyticsCollection(enabled: state.analyticsEnabled);
  }

  /// 撤回同意（CN：撤回同意入口）。停采集 + 清本地数据 + 复位。
  ///
  /// 顺序很重要：必须先停掉跟踪/长连接/会话，再删数据 ——
  /// 否则清理过程中定位仍可能继续上报，撤回同意就形同虚设。
  Future<void> revokePrivacy() async {
    // 0) 停止一切采集路径（跟踪引擎、WebSocket、内存会话）。
    //    由 app 层注入实现，避免 settings 反向依赖 tracking/auth。
    try {
      await ref.read(privacyTeardownProvider)();
    } on Object catch (error) {
      AppLog.w('privacy', 'teardown failed (ignored): $error');
    }

    // 1) 第三方 SDK。
    try {
      await ref.read(crashReporterProvider).disable();
    } on Object {
      // 忽略。
    }
    try {
      await _syncAnalyticsCollection(enabled: false);
    } on Object catch (error) {
      AppLog.w('privacy', 'analytics disable failed: $error');
    }

    // 2) 本地落点：数据库、Secure Storage、日志、导出文件。
    await _eraseLocalStores();

    // 3) 同意记录：隐私门、后台定位单独同意、地图 SDK 单独同意。
    try {
      await _clearConsentRecords(includeAnalytics: true);
    } on Object catch (error) {
      // 即使存储写入失败，也要把内存状态置为未同意，路由守卫会立即生效。
      AppLog.w('privacy', 'consent reset failed: $error');
    }

    state = state.copyWith(
      privacyAgreed: false,
      privacyPolicyVersion: 0,
      analyticsEnabled: false,
    );
  }

  /// H-5：把「匿名统计」开关与真实采集绑定。
  ///
  /// 中国大陆包（`MAP_PROVIDER=amap` / 未配置 Firebase）不加载分析 SDK，
  /// 开关只是偏好记录；海外包才实际操作 FirebaseAnalytics。
  Future<void> _syncAnalyticsCollection({required bool enabled}) async {
    if (BuildConfig.crashReporter != 'firebase') return;
    // 具体的 Analytics 接线在海外 flavor 完成；此处保证开关语义正确：
    // 未同意 → 永不采集；同意且开关开 → 采集。
    final allowed = enabled && state.privacyAgreed;
    final prefs = ref.read(prefsProvider);
    await prefs.setBool(PrefKeys.analyticsEnabled, allowed);
  }

  /// H-6：删除本地数据要覆盖**全部**落点，而不只是 SQLite：
  /// 1. drift 缓存（设备/位置/事件/队列/跟踪快照）
  /// 2. Secure Storage 中的 Token 与保存的密码
  /// 3. 7 天日志文件（含设备名与事件正文）
  /// 4. 历史导出的临时 GPX/KML/CSV（全精度 WGS-84）
  /// 5. 地图隐私同意与后台定位同意记录
  ///
  /// 凭据被清除后内存会话不再可信，因此这里的第 0 步也会停止采集
  /// 并复位会话（与撤回同意共用 [privacyTeardownProvider]）。
  Future<LocalWipeReport> wipeLocalData() async {
    final report = LocalWipeReport();

    // 0) 先停采集：定位服务一边删一边传会让「删除」失去意义。
    try {
      await ref.read(privacyTeardownProvider)();
      report.collection = true;
    } on Object catch (error) {
      AppLog.w('privacy', 'wipe teardown failed (ignored): $error');
      report.collection = false;
    }

    // 1) 数据库缓存。
    try {
      await ref.read(appDatabaseProvider).wipeAllCache();
      report.database = true;
    } on Object {
      report.database = false;
    }

    // 2) 凭据。
    try {
      await ref.read(secureStoreProvider).clear();
      report.credentials = true;
    } on Object {
      report.credentials = false;
    }

    // 3) 日志文件。
    try {
      report.logs = await ref.read(logEraserProvider)();
    } on Object {
      report.logs = false;
    }

    // 4) 临时导出文件。
    try {
      report.exports = await ref.read(exportEraserProvider)();
    } on Object {
      report.exports = false;
    }

    // 5) 同意记录（撤回同意语义）。
    try {
      await _clearConsentRecords(includeAnalytics: false);
      report.consents = true;
    } on Object {
      report.consents = false;
    }

    state = state.copyWith(privacyAgreed: false, privacyPolicyVersion: 0);
    return report;
  }

  /// 删除本地数据时的公共落点（DB / Secure / 日志 / 导出）。
  Future<void> _eraseLocalStores() async {
    try {
      await ref.read(appDatabaseProvider).wipeAllCache();
    } on Object catch (error) {
      AppLog.w('privacy', 'wipe database failed: $error');
    }
    try {
      await ref.read(secureStoreProvider).clear();
    } on Object catch (error) {
      AppLog.w('privacy', 'wipe credentials failed: $error');
    }
    try {
      await ref.read(logEraserProvider)();
    } on Object catch (error) {
      AppLog.w('privacy', 'wipe logs failed: $error');
    }
    try {
      await ref.read(exportEraserProvider)();
    } on Object catch (error) {
      AppLog.w('privacy', 'wipe exports failed: $error');
    }
  }

  /// 清除所有「同意」记录，包括地图 SDK 的单独同意（高德要求）。
  Future<void> _clearConsentRecords({required bool includeAnalytics}) async {
    final prefs = ref.read(prefsProvider);
    await prefs.setBool(PrefKeys.privacyAgreed, false);
    await prefs.remove(PrefKeys.privacyAgreedAt);
    await prefs.remove(PrefKeys.privacyPolicyVersion);
    await prefs.remove(PrefKeys.backgroundLocationConsent);
    if (includeAnalytics) {
      await prefs.remove(PrefKeys.analyticsEnabled);
    }
    await ref.read(mapPrivacyConsentStoreProvider).write(
          MapPrivacyConsentNotifier.providerId,
          false,
        );
    ref.invalidate(mapPrivacyConsentProvider);
  }
}

/// 撤回隐私 / 删除本地数据时，由 app 层注入的「停止一切采集」钩子。
///
/// 默认空实现（单元测试无需拉起跟踪引擎）；`main()` 中覆盖为
/// 停止跟踪 → 断开 WebSocket → 复位内存会话。
/// 放在这里而不是直接依赖 tracking/auth，避免 settings 反向依赖 feature。
final privacyTeardownProvider = Provider<Future<void> Function()>(
  (ref) => () async {},
);

/// 删除结果（诊断/设置页可展示哪些清除成功）。
class LocalWipeReport {
  LocalWipeReport({
    this.collection = false,
    this.database = false,
    this.credentials = false,
    this.logs = false,
    this.exports = false,
    this.consents = false,
  });

  /// 是否已停止采集（跟踪 / 长连接 / 会话）。
  bool collection;
  bool database;
  bool credentials;
  bool logs;
  bool exports;
  bool consents;

  bool get allSucceeded =>
      collection &&
      database &&
      credentials &&
      logs &&
      exports &&
      consents;
}

/// 删除日志文件（main() 中注入 DataEraser.eraseLogs）。
final logEraserProvider = Provider<Future<bool> Function()>((ref) {
  throw UnimplementedError('必须在 main() 中 override logEraserProvider');
});

/// 删除历史导出临时文件（main() 中注入 DataEraser.eraseExports）。
final exportEraserProvider = Provider<Future<bool> Function()>((ref) {
  throw UnimplementedError('必须在 main() 中 override exportEraserProvider');
});

final settingsProvider =
    NotifierProvider<SettingsController, AppSettings>(SettingsController.new);

/// 单位换算（docs/02 §6：数字与单位本地化）。返回已换算的数值字符串，
/// 单位文案由 UI 层的 l10n 模板（unitKmh 等）包装。
String speedValue(AppSettings settings, double metersPerSecond) {
  return settings.units == UnitSystem.imperial
      ? (metersPerSecond * 2.236936).toStringAsFixed(0) // mph
      : (metersPerSecond * 3.6).toStringAsFixed(0); // km/h
}

String speedUnit(AppSettings settings) =>
    settings.units == UnitSystem.imperial ? 'mph' : 'km/h';

String distanceValue(AppSettings settings, double meters) {
  if (settings.units == UnitSystem.imperial) {
    return meters >= 160.9
        ? (meters / 1609.344).toStringAsFixed(1) // mi
        : (meters * 3.28084).toStringAsFixed(0); // ft
  }
  return meters >= 1000
      ? (meters / 1000).toStringAsFixed(1) // km
      : meters.toStringAsFixed(0); // m
}

/// 长距离用 km/mi，短距离用 m/ft（决定 UI 选哪个模板）。
bool distanceIsLong(AppSettings settings, double meters) =>
    settings.units == UnitSystem.imperial ? meters >= 160.9 : meters >= 1000;

String distanceShortUnit(AppSettings settings) =>
    settings.units == UnitSystem.imperial ? 'ft' : 'm';

String distanceLongUnit(AppSettings settings) =>
    settings.units == UnitSystem.imperial ? 'mi' : 'km';
