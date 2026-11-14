import '../../../core/storage/preferences.dart';
import '../../../core/tracking/tracking_engine.dart';

/// 跟踪预设（TRK-08，docs/05 §4.2）。
enum TrackingPreset {
  walking,
  driving,
  asset,
  highFrequency,
  powerSaver,
  custom;

  TrackingConfig applyTo(TrackingConfig base) => switch (this) {
        TrackingPreset.walking => base.copyWith(
            accuracy: TrackingAccuracy.high,
            intervalSeconds: 60,
            distanceMeters: 20,
            angleDegrees: 15,
            stopDetection: true,
          ),
        TrackingPreset.driving => base.copyWith(
            accuracy: TrackingAccuracy.high,
            intervalSeconds: 30,
            distanceMeters: 50,
            angleDegrees: 10,
            stopDetection: true,
          ),
        TrackingPreset.asset => base.copyWith(
            accuracy: TrackingAccuracy.medium,
            intervalSeconds: 600,
            distanceMeters: 200,
            angleDegrees: 0,
            stopDetection: true,
          ),
        TrackingPreset.highFrequency => base.copyWith(
            accuracy: TrackingAccuracy.highest,
            intervalSeconds: 10,
            distanceMeters: 0,
            angleDegrees: 0,
            stopDetection: false,
          ),
        TrackingPreset.powerSaver => base.copyWith(
            accuracy: TrackingAccuracy.low,
            intervalSeconds: 1800,
            distanceMeters: 500,
            angleDegrees: 0,
            stopDetection: true,
          ),
        TrackingPreset.custom => base,
      };
}

/// 跟踪配置持久化（TRK-06/07；键见 docs/03 §7.3）。
///
/// 只存**非敏感**项；reportUrl / uniqueId 中的设备标识不算敏感（8 位数字），
/// 但 uniqueId 属于设备标识，按 PRD 数据表放 Prefs（非 Token）。
class TrackingPrefsStore {
  TrackingPrefsStore(this._prefs);

  final Prefs _prefs;

  static const int defaultInterval = 300;
  static const int defaultDistance = 75;

  TrackingConfig load({
    required String reportUrl,
    required String deviceId,
    required String notificationText,
  }) {
    final base = TrackingConfig(
      reportUrl: reportUrl,
      deviceId: deviceId,
      notificationText: notificationText,
    );
    final presetIndex = _prefs.getInt(PrefKeys.trackingPreset) ?? 0;
    final preset = TrackingPreset.values[presetIndex.clamp(0, TrackingPreset.values.length - 1)];
    final configured = base.copyWith(
      accuracy: _accuracyFromPrefs() ?? TrackingAccuracy.medium,
      intervalSeconds: _prefs.getInt(PrefKeys.trackingInterval) ?? defaultInterval,
      distanceMeters: _prefs.getInt(PrefKeys.trackingDistance) ?? defaultDistance,
      angleDegrees: _prefs.getInt(PrefKeys.trackingAngle) ?? 0,
      heartbeatIntervalSeconds: _prefs.getInt(PrefKeys.trackingHeartbeat) ?? 0,
      buffer: _prefs.getBool(PrefKeys.trackingBuffer) ?? true,
      stopDetection: _prefs.getBool(PrefKeys.trackingStopDetection) ?? true,
      wakeLock: _prefs.getBool(PrefKeys.trackingWakeLock) ?? false,
      preferPlatformProviders: _prefs.getBool(PrefKeys.trackingPreferPlatform) ?? false,
    );
    // 用户显式选择预设时应用预设；custom 时用逐项配置。
    return preset == TrackingPreset.custom ? configured : preset.applyTo(base);
  }

  TrackingAccuracy? _accuracyFromPrefs() {
    final index = _prefs.getInt(PrefKeys.trackingAccuracy);
    if (index == null) return null;
    return TrackingAccuracy.values[index.clamp(0, TrackingAccuracy.values.length - 1)];
  }

  Future<void> savePreset(TrackingPreset preset) =>
      _prefs.setInt(PrefKeys.trackingPreset, preset.index);

  TrackingPreset loadPreset() {
    final index = _prefs.getInt(PrefKeys.trackingPreset) ?? 0;
    return TrackingPreset.values[index.clamp(0, TrackingPreset.values.length - 1)];
  }

  Future<void> save(TrackingConfig config) async {
    await _prefs.setInt(PrefKeys.trackingAccuracy, config.accuracy.index);
    await _prefs.setInt(PrefKeys.trackingInterval, config.intervalSeconds);
    await _prefs.setInt(PrefKeys.trackingDistance, config.distanceMeters);
    await _prefs.setInt(PrefKeys.trackingAngle, config.angleDegrees);
    await _prefs.setInt(
      PrefKeys.trackingHeartbeat,
      config.heartbeatIntervalSeconds,
    );
    await _prefs.setBool(PrefKeys.trackingBuffer, config.buffer);
    await _prefs.setBool(PrefKeys.trackingStopDetection, config.stopDetection);
    await _prefs.setBool(PrefKeys.trackingWakeLock, config.wakeLock);
    await _prefs.setBool(
      PrefKeys.trackingPreferPlatform,
      config.preferPlatformProviders,
    );
  }
}

/// 本机设备标识（TRK-01：首次生成 8 位数字，与旧 Client 兼容）。
///
/// 首位 1–9，避免前导 0 在服务端被文本化后不一致；
/// 进程内用自增计数保证同一微秒内多次调用也不重复。
int _uniqueIdCounter = 0;

String generateUniqueUniqueId() {
  final seed = DateTime.now().microsecondsSinceEpoch + (_uniqueIdCounter++);
  final first = 1 + seed % 9;
  final rest = (seed ~/ 9) % 10000000;
  return '$first${rest.toString().padLeft(7, '0')}'.substring(0, 8);
}
