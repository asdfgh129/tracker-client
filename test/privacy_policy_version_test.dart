import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:trackerone/core/storage/preferences.dart';
import 'package:trackerone/features/onboarding/presentation/privacy_gate_screen.dart';
import 'package:trackerone/features/settings/application/settings_controller.dart';
import 'package:trackerone/l10n/app_localizations.dart';

/// 固定初始设置的 SettingsController（跳过 prefs 读取）。
class FakeSettingsController extends SettingsController {
  FakeSettingsController(AppSettings initial) : _initial = initial;

  final AppSettings _initial;

  @override
  AppSettings build() => _initial;
}

void main() {
  group('隐私政策版本号（CN-05）', () {
    test('未同意过：门不放行', () {
      final settings =
          const AppSettings(privacyAgreed: false, privacyPolicyVersion: 0);
      expect(settings.privacyGatePassed, isFalse);
    });

    test('同意了当前版本：门放行', () {
      final settings = AppSettings(
        privacyAgreed: true,
        privacyPolicyVersion: SettingsController.privacyPolicyCurrentVersion,
      );
      expect(settings.privacyGatePassed, isTrue);
    });

    test('同意了旧版本（政策升级后）：门不放行，需重新同意', () {
      final settings = AppSettings(
        privacyAgreed: true,
        privacyPolicyVersion: SettingsController.privacyPolicyCurrentVersion - 1,
      );
      expect(settings.privacyGatePassed, isFalse);
    });

    test('只有布尔同意、无版本记录（存量用户）：门不放行一次后恢复', () {
      // 存量用户只有 privacyAgreed=true、version=0 → 政策升级后强制重同意一次。
      final legacy = const AppSettings(privacyAgreed: true);
      expect(legacy.privacyGatePassed, isFalse);
      final reAgreed = legacy.copyWith(
        privacyPolicyVersion: SettingsController.privacyPolicyCurrentVersion,
      );
      expect(reAgreed.privacyGatePassed, isTrue);
    });
  });

  group('PrivacyGateScreen（widget）', () {
    Widget host(AppSettings settings, InMemoryPrefs prefs) {
      final router = GoRouter(
        initialLocation: '/privacy',
        routes: [
          GoRoute(
            path: '/privacy',
            builder: (_, _) => const PrivacyGateScreen(),
          ),
          GoRoute(
            path: '/onboarding/mode',
            builder: (_, _) => const Scaffold(body: Text('mode-select')),
          ),
        ],
      );
      return ProviderScope(
        overrides: [
          prefsProvider.overrideWithValue(prefs),
          settingsProvider.overrideWith(() => FakeSettingsController(settings)),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      );
    }

    testWidgets('未同意时展示同意与拒绝入口', (tester) async {
      await tester.pumpWidget(
        host(const AppSettings(privacyAgreed: false), InMemoryPrefs()),
      );

      expect(find.byIcon(Icons.privacy_tip_outlined), findsOneWidget);
      expect(find.byType(FilledButton), findsOneWidget); // 同意
      expect(find.byType(TextButton), findsNWidgets(2)); // 完整政策 / 拒绝
    });

    testWidgets('点击同意：写入当前政策版本并跳转模式选择', (tester) async {
      final prefs = InMemoryPrefs();
      await tester.pumpWidget(
        host(const AppSettings(privacyAgreed: false), prefs),
      );

      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();

      // 同意状态落库（布尔 + 版本号 + 时间戳）。
      expect(prefs.getBool('app.privacy.agreed'), isTrue);
      expect(
        prefs.getInt('app.privacy.policyVersion'),
        SettingsController.privacyPolicyCurrentVersion,
      );
      expect(prefs.getString('app.privacy.agreedAt'), isNotNull);
      // 已跳转到模式选择页。
      expect(find.text('mode-select'), findsOneWidget);
    });

    testWidgets('点击拒绝：仅弹 SnackBar，不写同意记录', (tester) async {
      final prefs = InMemoryPrefs();
      await tester.pumpWidget(
        host(const AppSettings(privacyAgreed: false), prefs),
      );

      await tester.tap(find.byType(TextButton).last);
      await tester.pump();

      expect(prefs.getBool('app.privacy.agreed'), isNull);
      expect(find.byType(SnackBar), findsOneWidget);
    });
  });
}
