import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trackerone/core/map/map_privacy_consent.dart';
import 'package:trackerone/core/observability/crash_reporter.dart';
import 'package:trackerone/core/providers.dart';
import 'package:trackerone/core/storage/preferences.dart';
import 'package:trackerone/core/storage/secure_store.dart';
import 'package:trackerone/features/settings/application/settings_controller.dart';

/// P0 回归：撤回隐私同意必须先停采集，再清掉全部本地落点与同意记录。
class _MemoryMapConsent implements MapPrivacyConsentStore {
  _MemoryMapConsent({this.agreed = false});

  final Map<String, bool> _values = {};
  bool agreed;

  @override
  Future<bool> read(String providerId) async => _values[providerId] ?? agreed;

  @override
  Future<void> write(String providerId, bool value) async {
    _values[providerId] = value;
    agreed = value;
  }
}

void main() {
  late InMemoryPrefs prefs;
  late InMemorySecureStore secure;
  late _MemoryMapConsent mapConsent;
  late ProviderContainer container;
  var teardownCalls = 0;

  setUp(() async {
    teardownCalls = 0;
    prefs = InMemoryPrefs();
    secure = InMemorySecureStore();
    mapConsent = _MemoryMapConsent(agreed: true);

    await prefs.setBool(PrefKeys.privacyAgreed, true);
    await prefs.setInt(
      PrefKeys.privacyPolicyVersion,
      SettingsController.privacyPolicyCurrentVersion,
    );
    await prefs.setBool(PrefKeys.backgroundLocationConsent, true);
    await prefs.setBool(PrefKeys.analyticsEnabled, true);
    await secure.write(SecureKeys.token(1), 'secret-token');
    await secure.write(SecureKeys.password(1), 'secret-password');

    container = ProviderContainer(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        secureStoreProvider.overrideWithValue(secure),
        crashReporterProvider.overrideWithValue(const NoopCrashReporter()),
        mapPrivacyConsentStoreProvider.overrideWithValue(mapConsent),
        // 撤回流程不依赖真实数据库；这里模拟“数据库不可用”，
        // 用来验证单点失败不会阻断同意撤回。
        appDatabaseProvider.overrideWith((ref) => throw StateError('no db')),
        logEraserProvider.overrideWithValue(() async => true),
        exportEraserProvider.overrideWithValue(() async => true),
        privacyTeardownProvider.overrideWithValue(() async {
          teardownCalls++;
        }),
      ],
    );
    addTearDown(container.dispose);
  });

  test('revokePrivacy 先停采集，再清凭据与全部同意记录', () async {
    expect(await container.read(mapPrivacyConsentProvider.future), isTrue);

    await container.read(settingsProvider.notifier).revokePrivacy();

    expect(teardownCalls, 1, reason: '必须先停止跟踪/长连接/会话');
    expect(prefs.getBool(PrefKeys.privacyAgreed), isFalse);
    expect(prefs.getString(PrefKeys.privacyAgreedAt), isNull);
    expect(prefs.getInt(PrefKeys.privacyPolicyVersion), isNull);
    expect(prefs.getBool(PrefKeys.backgroundLocationConsent), isNull);
    expect(prefs.getBool(PrefKeys.analyticsEnabled), isNull);
    expect(await secure.read(SecureKeys.token(1)), isNull);
    expect(await secure.read(SecureKeys.password(1)), isNull);
    expect(mapConsent.agreed, isFalse, reason: '地图 SDK 单独同意也必须撤回');
    expect(container.read(settingsProvider).privacyAgreed, isFalse);
  });

  test('wipeLocalData 报告包含 collection 且清除地图同意', () async {
    final report =
        await container.read(settingsProvider.notifier).wipeLocalData();

    expect(report.collection, isTrue);
    expect(teardownCalls, 1);
    expect(mapConsent.agreed, isFalse);
    expect(await secure.read(SecureKeys.token(1)), isNull);
  });
}
