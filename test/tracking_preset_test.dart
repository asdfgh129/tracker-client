import 'package:flutter_test/flutter_test.dart';
import 'package:trackerone/core/storage/preferences.dart';
import 'package:trackerone/core/tracking/tracking_engine.dart';
import 'package:trackerone/features/tracking/application/tracking_profile.dart';

/// P1 回归：预设只应覆盖预设字段，且手动调整必须落盘为 custom。
void main() {
  test('preset keeps user-saved heartbeat / wakeLock / buffer', () async {
    final prefs = InMemoryPrefs();
    final store = TrackingPrefsStore(prefs);

    await store.save(
      const TrackingConfig(
        reportUrl: 'https://srv:5055',
        deviceId: '12345678',
        intervalSeconds: 45,
        heartbeatIntervalSeconds: 120,
        wakeLock: true,
        buffer: false,
      ),
    );
    await store.savePreset(TrackingPreset.powerSaver);

    final loaded = store.load(
      reportUrl: 'https://srv:5055',
      deviceId: '12345678',
      notificationText: 'x',
    );

    // 预设字段生效。
    expect(loaded.intervalSeconds, 1800);
    expect(loaded.distanceMeters, 500);
    // 用户逐项配置不能被预设整块丢弃。
    expect(loaded.heartbeatIntervalSeconds, 120);
    expect(loaded.wakeLock, isTrue);
    expect(loaded.buffer, isFalse);
  });

  test('custom preset round-trips all saved fields', () async {
    final prefs = InMemoryPrefs();
    final store = TrackingPrefsStore(prefs);

    await store.save(
      const TrackingConfig(
        reportUrl: 'https://srv:5055',
        deviceId: '12345678',
        accuracy: TrackingAccuracy.highest,
        intervalSeconds: 15,
        distanceMeters: 10,
        angleDegrees: 5,
        heartbeatIntervalSeconds: 60,
        wakeLock: true,
      ),
    );
    await store.savePreset(TrackingPreset.custom);

    final loaded = store.load(
      reportUrl: 'https://srv:5055',
      deviceId: '12345678',
      notificationText: 'x',
    );
    expect(loaded.accuracy, TrackingAccuracy.highest);
    expect(loaded.intervalSeconds, 15);
    expect(loaded.distanceMeters, 10);
    expect(loaded.heartbeatIntervalSeconds, 60);
    expect(loaded.wakeLock, isTrue);
  });
}
