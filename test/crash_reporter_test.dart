import 'package:flutter_test/flutter_test.dart';
import 'package:trackerone/core/observability/crash_reporter.dart';

/// 记录调用的假桥（不依赖 MethodChannel）。
class _FakeBuglyBridge implements BuglyBridge {
  final List<Map<String, Object?>> reports = <Map<String, Object?>>[];
  int initCalls = 0;
  int closeCalls = 0;
  bool initResult = true;
  bool throwOnInit = false;

  @override
  Future<bool> init(String appId, bool debug) async {
    initCalls++;
    if (throwOnInit) throw StateError('bridge unavailable');
    return initResult;
  }

  @override
  Future<void> close() async {
    closeCalls++;
  }

  @override
  Future<void> reportError({
    required String name,
    required String reason,
    required List<String> callStack,
    required bool fatal,
  }) async {
    reports.add({
      'name': name,
      'reason': reason,
      'stack': callStack.join('\n'),
      'fatal': fatal,
    });
  }
}

void main() {
  group('CrashReporterFactory（0.5.1 Bugly）', () {
    test('bugly + appId → BuglyCrashReporter；appId 缺失 → Noop（fail-closed）',
        () {
      expect(
        CrashReporterFactory.preparePending(
          reporter: 'bugly',
          appId: 'abc1234567',
        ),
        isA<BuglyCrashReporter>(),
      );
      expect(
        CrashReporterFactory.preparePending(reporter: 'bugly', appId: ''),
        isA<NoopCrashReporter>(),
      );
    });

    test('none / firebase / 未知取值', () {
      expect(
        CrashReporterFactory.preparePending(reporter: 'none', appId: 'x'),
        isA<NoopCrashReporter>(),
      );
      expect(
        CrashReporterFactory.preparePending(reporter: 'firebase', appId: ''),
        isA<FirebaseCrashReporter>(),
      );
      expect(
        CrashReporterFactory.preparePending(reporter: 'weird', appId: 'x'),
        isA<NoopCrashReporter>(),
      );
    });
  });

  group('BuglyCrashReporter（同意门控 + 脱敏）', () {
    test('debug 构建不初始化（避免污染线上数据）', () async {
      final bridge = _FakeBuglyBridge();
      final reporter = BuglyCrashReporter(
        bridge: bridge,
        debugMode: true,
        appId: 'abc1234567',
      );

      await reporter.initialize();

      expect(reporter.enabled, isFalse);
      expect(bridge.initCalls, 0);
    });

    test('appId 缺失不初始化（fail-closed）', () async {
      final bridge = _FakeBuglyBridge();
      final reporter = BuglyCrashReporter(
        bridge: bridge,
        debugMode: false,
        appId: '',
      );

      await reporter.initialize();

      expect(reporter.enabled, isFalse);
      expect(bridge.initCalls, 0);
    });

    test('同意后初始化成功 → enabled；撤回 → close 调用', () async {
      final bridge = _FakeBuglyBridge();
      final reporter = BuglyCrashReporter(
        bridge: bridge,
        debugMode: false,
        appId: 'abc1234567',
      );

      await reporter.initialize();
      expect(reporter.enabled, isTrue);
      expect(bridge.initCalls, 1);

      await reporter.disable();
      expect(reporter.enabled, isFalse);
      expect(bridge.closeCalls, 1);
    });

    test('桥接失败降级 noop（不抛、不采集）', () async {
      final bridge = _FakeBuglyBridge()..throwOnInit = true;
      final reporter = BuglyCrashReporter(
        bridge: bridge,
        debugMode: false,
        appId: 'abc1234567',
      );

      await reporter.initialize();

      expect(reporter.enabled, isFalse);
      reporter.recordError(StateError('boom'), StackTrace.current);
      expect(bridge.reports, isEmpty);
    });

    test('未启用时 recordError 不过桥', () async {
      final bridge = _FakeBuglyBridge();
      final reporter = BuglyCrashReporter(
        bridge: bridge,
        debugMode: false,
        appId: 'abc1234567',
      );

      reporter.recordError(StateError('boom'), StackTrace.current);

      expect(bridge.reports, isEmpty);
    });

    test('启用后上报：reason/stack 先过 LogRedactor（不含 token/精确坐标）',
        () async {
      final bridge = _FakeBuglyBridge();
      final reporter = BuglyCrashReporter(
        bridge: bridge,
        debugMode: false,
        appId: 'abc1234567',
      );
      await reporter.initialize();

      reporter.recordError(
        StateError(
          'GET /api/devices?token=abcdef1234567890abcdef1234567890 failed '
          'at 39.90421,116.407389',
        ),
        StackTrace.fromString(
          '#0  Api.fetch (file:///lib/core/network/traccar_api.dart:42)',
        ),
        fatal: true,
      );
      await Future<void>.delayed(Duration.zero);

      expect(bridge.reports, hasLength(1));
      final report = bridge.reports.single;
      expect(report['fatal'], isTrue);
      final reason = report['reason']! as String;
      expect(reason, isNot(contains('abcdef1234567890abcdef1234567890')));
      expect(reason, isNot(contains('39.90421')));
      expect(reason, contains('39.904'));
      // 栈同样过脱敏：长路径段被 <redacted>，符号名与行号保留（可读性平衡）。
      final stack = report['stack']! as String;
      expect(stack, contains('Api.fetch'));
      expect(stack, contains('.dart:42'));
    });
  });
}
