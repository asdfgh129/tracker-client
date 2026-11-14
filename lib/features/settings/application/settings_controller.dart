import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/build_config.dart';
import '../../../core/observability/crash_reporter.dart';
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
    this.notificationsEnabled = false,
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
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
    );
  }
}

/// 设置控制器。
class SettingsController extends Notifier<AppSettings> {
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
      notificationsEnabled: prefs.getBool(PrefKeys.notificationsEnabled) ?? false,
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
    await prefs.setString(
      PrefKeys.privacyAgreedAt,
      DateTime.now().toUtc().toIso8601String(),
    );
    state = state.copyWith(privacyAgreed: true);

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
  Future<void> revokePrivacy() async {
    final prefs = ref.read(prefsProvider);

    // 先停所有采集路径，再清数据（顺序重要：避免清理过程中继续上报）。
    try {
      await ref.read(crashReporterProvider).disable();
    } on Object {
      // 忽略。
    }
    await _syncAnalyticsCollection(enabled: false);

    await prefs.setBool(PrefKeys.privacyAgreed, false);
    await prefs.remove(PrefKeys.privacyAgreedAt);
    await prefs.remove(PrefKeys.analyticsEnabled);
    await ref.read(appDatabaseProvider).wipeAllCache();
    state = state.copyWith(privacyAgreed: false, analyticsEnabled: false);
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
  Future<LocalWipeReport> wipeLocalData() async {
    final report = LocalWipeReport();

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
      final prefs = ref.read(prefsProvider);
      await prefs.remove(PrefKeys.backgroundLocationConsent);
      await prefs.setBool(PrefKeys.privacyAgreed, false);
      await prefs.remove(PrefKeys.privacyAgreedAt);
      report.consents = true;
    } on Object {
      report.consents = false;
    }

    state = state.copyWith(privacyAgreed: false);
    return report;
  }
}

/// 删除结果（诊断/设置页可展示哪些清除成功）。
class LocalWipeReport {
  LocalWipeReport({
    this.database = false,
    this.credentials = false,
    this.logs = false,
    this.exports = false,
    this.consents = false,
  });

  bool database;
  bool credentials;
  bool logs;
  bool exports;
  bool consents;

  bool get allSucceeded =>
      database && credentials && logs && exports && consents;
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
