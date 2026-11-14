import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 命名空间化的偏好键（docs/03 §7.3）。
///
/// 统一入口避免旧项目 `url` 之类的裸键冲突；只允许放**非敏感**配置。
/// Token / 密码一律走 [SecureStore]。
abstract final class PrefKeys {
  // 应用
  static const themeMode = 'app.theme'; // system / light / dark
  static const locale = 'app.locale'; // '' = 跟随系统
  static const units = 'app.units'; // metric / imperial
  static const usageMode = 'app.mode'; // track / view / both

  // 合规
  static const privacyAgreed = 'app.privacy.agreed';
  static const privacyAgreedAt = 'app.privacy.agreedAt';

  /// 已同意的隐私政策版本号。条款实质变更时递增
  /// [SettingsController.privacyPolicyCurrentVersion] 强制重新同意。
  static const privacyPolicyVersion = 'app.privacy.policyVersion';
  static const backgroundLocationConsent = 'app.privacy.bgLocationConsent';
  static const analyticsEnabled = 'app.privacy.analyticsEnabled';

  // 地图
  static const mapStyle = 'map.style'; // standard / satellite / night
  static const mapTrailEnabled = 'map.trail';
  static const mapClusteringEnabled = 'map.clustering';

  // 通知
  static const notificationsEnabled = 'notifications.enabled';
  static const doNotDisturbFrom = 'notifications.dnd.from'; // 'HH:mm'
  static const doNotDisturbTo = 'notifications.dnd.to';

  // 跟踪（serverId 维度的配置见 TrackingPrefs）
  static const trackingDeviceId = 'tracking.deviceId'; // 本机设备服务端 id
  static const trackingUniqueId = 'tracking.uniqueId'; // 本机设备 uniqueId
  static const trackingPreset = 'tracking.preset';
  static const trackingAccuracy = 'tracking.accuracy';
  static const trackingInterval = 'tracking.interval';
  static const trackingDistance = 'tracking.distance';
  static const trackingAngle = 'tracking.angle';
  static const trackingHeartbeat = 'tracking.heartbeat';
  static const trackingBuffer = 'tracking.buffer';
  static const trackingStopDetection = 'tracking.stopDetection';
  static const trackingWakeLock = 'tracking.wakeLock';
  static const trackingPreferPlatform = 'tracking.preferPlatformProviders';

  // 诊断
  static const diagnosticsUploadLogs = 'diagnostics.uploadLogs';
}

/// 偏好读写门面。测试可用内存实现替换。
abstract interface class Prefs {
  String? getString(String key);
  Future<void> setString(String key, String value);
  int? getInt(String key);
  Future<void> setInt(String key, int value);
  bool? getBool(String key);
  Future<void> setBool(String key, bool value);
  double? getDouble(String key);
  Future<void> setDouble(String key, double value);
  Future<void> remove(String key);
  Future<void> clear();
}

/// SharedPreferences 实现。
class SharedPrefs implements Prefs {
  SharedPrefs(this._prefs);

  final SharedPreferences _prefs;

  @override
  String? getString(String key) => _prefs.getString(key);

  @override
  Future<void> setString(String key, String value) =>
      _prefs.setString(key, value);

  @override
  int? getInt(String key) => _prefs.getInt(key);

  @override
  Future<void> setInt(String key, int value) => _prefs.setInt(key, value);

  @override
  bool? getBool(String key) => _prefs.getBool(key);

  @override
  Future<void> setBool(String key, bool value) => _prefs.setBool(key, value);

  @override
  double? getDouble(String key) => _prefs.getDouble(key);

  @override
  Future<void> setDouble(String key, double value) =>
      _prefs.setDouble(key, value);

  @override
  Future<void> remove(String key) => _prefs.remove(key);

  @override
  Future<void> clear() => _prefs.clear();
}

/// 异步初始化完成的共享实例。
final sharedPrefsProvider = FutureProvider<SharedPreferences>(
  (ref) => SharedPreferences.getInstance(),
);

/// 同步可用的 Prefs；在 main() 里 prewarm 后覆盖。
final prefsProvider = Provider<Prefs>((ref) {
  throw UnimplementedError('必须在 main() 中用 override 注入 Prefs');
});

/// 内存实现（测试）。
class InMemoryPrefs implements Prefs {
  final Map<String, Object> _values = {};

  @override
  String? getString(String key) => _values[key] as String?;

  @override
  Future<void> setString(String key, String value) async =>
      _values[key] = value;

  @override
  int? getInt(String key) => _values[key] as int?;

  @override
  Future<void> setInt(String key, int value) async => _values[key] = value;

  @override
  bool? getBool(String key) => _values[key] as bool?;

  @override
  Future<void> setBool(String key, bool value) async => _values[key] = value;

  @override
  double? getDouble(String key) => _values[key] as double?;

  @override
  Future<void> setDouble(String key, double value) async =>
      _values[key] = value;

  @override
  Future<void> remove(String key) async => _values.remove(key);

  @override
  Future<void> clear() async => _values.clear();
}
