import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/build_config.dart';

/// 崩溃上报抽象。
///
/// 中国大陆生产环境不能依赖 Crashlytics（需要 GMS），默认 [NoopCrashReporter]，
/// 后续接腾讯 Bugly 时新增实现即可。
///
/// H-5：第三方 SDK 必须**同意隐私政策后**才允许初始化（CN-05）。
/// 因此 [initialize] 由同意流程触发，而不是启动即调用。
abstract interface class CrashReporter {
  /// 采集是否已启用（同意后为 true）。
  bool get enabled;

  /// 初始化 SDK（仅在用户同意隐私政策后调用）。
  Future<void> initialize();

  /// 撤回同意：停止采集。
  Future<void> disable();

  void recordFlutterError(FlutterErrorDetails details);
  void recordError(Object error, StackTrace? stack, {bool fatal = false});
  Future<void> log(String message);
}

class NoopCrashReporter implements CrashReporter {
  const NoopCrashReporter();

  @override
  bool get enabled => false;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> disable() async {}

  @override
  void recordFlutterError(FlutterErrorDetails details) {}

  @override
  void recordError(Object error, StackTrace? stack, {bool fatal = false}) {}

  @override
  Future<void> log(String message) async {}
}

/// 海外 / 开发环境使用。初始化前不采集（H-5）。
class FirebaseCrashReporter implements CrashReporter {
  FirebaseCrashReporter();

  bool _enabled = false;

  @override
  bool get enabled => _enabled;

  @override
  Future<void> initialize() async {
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp();
      }
      // 仅在同意后开启采集；debug 构建始终关闭。
      _enabled = !kDebugMode;
      await FirebaseCrashlytics.instance
          .setCrashlyticsCollectionEnabled(_enabled);
    } on Object catch (error) {
      if (kDebugMode) {
        debugPrint('Crashlytics 初始化失败，降级为 noop: $error');
      }
      _enabled = false;
    }
  }

  @override
  Future<void> disable() async {
    _enabled = false;
    try {
      await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(false);
    } on Object {
      // 关闭失败也要保证本地上报路径停用。
    }
  }

  @override
  void recordFlutterError(FlutterErrorDetails details) {
    if (!_enabled || kDebugMode) return;
    FirebaseCrashlytics.instance.recordFlutterFatalError(details);
  }

  @override
  void recordError(Object error, StackTrace? stack, {bool fatal = false}) {
    if (!_enabled || kDebugMode) return;
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: fatal);
  }

  @override
  Future<void> log(String message) async {
    if (!_enabled || kDebugMode) return;
    await FirebaseCrashlytics.instance.log(message);
  }
}

/// 默认实现，测试或未配置时使用。
final crashReporterProvider = Provider<CrashReporter>(
  (ref) => const NoopCrashReporter(),
);

abstract final class CrashReporterFactory {
  /// 创建实现但**不初始化**（H-5：初始化推迟到隐私同意之后）。
  ///
  /// 关键点：Firebase 未配置（缺 google-services.json /
  /// GoogleService-Info.plist）时不能阻断启动，失败时降级为 noop。
  static CrashReporter preparePending() {
    if (BuildConfig.crashReporter != 'firebase') {
      return const NoopCrashReporter();
    }
    return FirebaseCrashReporter();
  }

  /// 兼容旧调用：创建并立即初始化（仅用于明确不要求同意门的场景，如测试）。
  @Deprecated('使用 preparePending() + 同意后 initialize()')
  static Future<CrashReporter> create() async {
    final reporter = preparePending();
    await reporter.initialize();
    return reporter;
  }
}

/// 安装全局错误处理。必须在 `runApp` 之前调用。
///
/// 处理器始终安装：即使采集未开启（未同意/未配置），也保证
/// `FlutterError.onError` 与 `PlatformDispatcher.onError` 有兜底，
/// 避免未捕获异常导致白屏。
void installCrashHandlers(CrashReporter reporter) {
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    reporter.recordFlutterError(details);
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    reporter.recordError(error, stack, fatal: true);
    return true;
  };
}
