import 'package:flutter_test/flutter_test.dart';
import 'package:trackerone/core/observability/logger.dart';
import 'package:trackerone/features/diagnostics/application/diagnosis.dart';
import 'package:trackerone/core/network/socket_client.dart';
import 'package:trackerone/features/tracking/application/tracking_profile.dart';
import 'package:trackerone/core/storage/preferences.dart';
import 'package:trackerone/core/tracking/tracking_engine.dart';

void main() {
  group('LogRedactor (docs/05 §9.3 脱敏)', () {
    test('redacts credential pairs', () {
      final redacted = LogRedactor.redact(
        'POST /api/session password=supersecret123 ok',
      );
      expect(redacted, isNot(contains('supersecret123')));
      expect(redacted, contains('<redacted>'));

      final bearer = LogRedactor.redact('Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.xxx.yyy');
      expect(bearer, isNot(contains('eyJhbGciOiJIUzI1NiJ9')));
    });

    test('redacts long random tokens', () {
      final redacted = LogRedactor.redact(
        'token=abcdef1234567890abcdef1234567890 done',
      );
      expect(redacted, isNot(contains('abcdef1234567890abcdef1234567890')));
    });

    test('rounds coordinates to 3 decimals', () {
      final redacted = LogRedactor.redact('pos 39.90421,116.407389');
      expect(redacted, contains('39.904'));
      expect(redacted, contains('116.407'));
      expect(redacted, isNot(contains('39.90421')));
    });

    test('redacts short Basic credentials and Base64 keys', () {
      // Basic 的值可能很短（用户名:密码），不能依赖 24 字符阈值。
      final basic = LogRedactor.redact('Authorization: Basic dXNlcjpwYXNz');
      expect(basic, isNot(contains('dXNlcjpwYXNz')));

      // Base64 字符集（含 + / =）的长密钥需被长串规则命中。
      final base64 = LogRedactor.redact('key AbC+dEf/gHi=JkL+mNo/PqR= done');
      expect(base64, isNot(contains('AbC+dEf/gHi=JkL+mNo/PqR=')));
    });

    test('keeps ordinary words intact', () {
      final redacted = LogRedactor.redact('tracking started interval=300');
      expect(redacted, contains('tracking started'));
      expect(redacted, contains('interval=300'));
    });
  });

  group('DiagnosisEngine (docs/05 §9.2)', () {
    DiagnosisInput input({
      bool background = true,
      bool running = true,
      DateTime? lastFix,
      int queue = 0,
      SocketStatus socket = SocketStatus.connected,
      bool serverReachable = true,
    }) {
      return DiagnosisInput(
        foregroundGranted: true,
        backgroundGranted: background,
        notificationGranted: true,
        motionGranted: true,
        trackingRunning: running,
        lastFixAt: lastFix ?? DateTime.now().toUtc(),
        lastUploadAt: DateTime.now().toUtc(),
        queueSize: queue,
        socketStatus: socket,
        serverReachable: serverReachable,
        clockSkewSeconds: 0,
        batteryOptimizationIgnored: true,
      );
    }

    test('healthy input yields ok', () {
      final conclusions = DiagnosisEngine.evaluate(input());
      expect(DiagnosisEngine.overall(conclusions), DiagnosisSeverity.ok);
      expect(conclusions.single.reason, DiagnosisReason.allGood);
    });

    test('missing background permission is first and fatal', () {
      final conclusions = DiagnosisEngine.evaluate(input(background: false));
      expect(conclusions.first.reason, DiagnosisReason.noBackgroundPermission);
      expect(conclusions.first.action, DiagnosisAction.openSettings);
      expect(DiagnosisEngine.overall(conclusions), DiagnosisSeverity.error);
    });

    test('10 minutes without fix warns', () {
      final conclusions = DiagnosisEngine.evaluate(
        input(lastFix: DateTime.now().toUtc().subtract(const Duration(minutes: 11))),
      );
      expect(
        conclusions.any((c) => c.reason == DiagnosisReason.noFixUpdate),
        isTrue,
      );
    });

    test('queued positions with unreachable server errors', () {
      final conclusions = DiagnosisEngine.evaluate(
        input(queue: 120, serverReachable: false),
      );
      expect(
        conclusions.any((c) => c.reason == DiagnosisReason.noUpload),
        isTrue,
      );
      expect(DiagnosisEngine.overall(conclusions), DiagnosisSeverity.error);
    });

    test('disconnected socket warns', () {
      final conclusions = DiagnosisEngine.evaluate(
        input(socket: SocketStatus.disconnected),
      );
      expect(
        conclusions.any((c) => c.reason == DiagnosisReason.socketDown),
        isTrue,
      );
    });
  });

  group('TrackingPreset (docs/05 §4.2)', () {
    test('driving preset applies interval/distance/angle/stop', () {
      final config = TrackingPreset.driving.applyTo(
        TrackingConfig(reportUrl: 'https://a:5055', deviceId: '1'),
      );
      expect(config.accuracy, TrackingAccuracy.high);
      expect(config.intervalSeconds, 30);
      expect(config.distanceMeters, 50);
      expect(config.angleDegrees, 10);
      expect(config.stopDetection, isTrue);
    });

    test('high frequency disables stop detection', () {
      final config = TrackingPreset.highFrequency.applyTo(
        TrackingConfig(reportUrl: 'https://a:5055', deviceId: '1'),
      );
      expect(config.intervalSeconds, 10);
      expect(config.stopDetection, isFalse);
    });

    test('unique id is 8 digits and unique-ish', () {
      final a = generateUniqueUniqueId();
      final b = generateUniqueUniqueId();
      expect(a, hasLength(8));
      expect(int.tryParse(a), isNotNull);
      expect(a[0], isNot('0'));
      // 时间源生成，连续调用应不同（毫秒级概率性通过）。
      expect(a == b, isFalse);
    });
  });

  group('InMemoryPrefs sanity', () {
    test('set/get round trip', () async {
      final prefs = InMemoryPrefs();
      await prefs.setString(PrefKeys.trackingUniqueId, '12345678');
      await prefs.setBool(PrefKeys.trackingBuffer, false);
      expect(prefs.getString(PrefKeys.trackingUniqueId), '12345678');
      expect(prefs.getBool(PrefKeys.trackingBuffer), isFalse);
      await prefs.remove(PrefKeys.trackingUniqueId);
      expect(prefs.getString(PrefKeys.trackingUniqueId), isNull);
    });
  });
}
