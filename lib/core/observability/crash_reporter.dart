import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/build_config.dart';
import 'logger.dart' show LogRedactor;

/// 崩溃上报抽象。
///
/// 中国大陆生产环境不能依赖 Crashlytics（需要 GMS），使用 [BuglyCrashReporter]
/// （腾讯 Bugly，0.5.1）；海外 [FirebaseCrashReporter]；默认 [NoopCrashReporter]。
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

/// Bugly 原生桥抽象（可注入，测试用 fake）。
abstract interface class BuglyBridge {
  /// 初始化 SDK，返回是否成功。
  Future<bool> init(String appId, bool debug);

  /// 关闭采集（Android 有 API；iOS 无对应 API，best-effort）。
  Future<void> close();

  /// 上报一条已脱敏的异常。
  Future<void> reportError({
    required String name,
    required String reason,
    required List<String> callStack,
    required bool fatal,
  });
}

/// 默认桥：MethodChannel `observability/bugly`（Android/iOS 各自实现）。
class MethodChannelBuglyBridge implements BuglyBridge {
  static const MethodChannel _channel = MethodChannel('observability/bugly');

  const MethodChannelBuglyBridge();

  @override
  Future<bool> init(String appId, bool debug) async {
    final ok = await _channel.invokeMethod<bool>(
      'init',
      {'appId': appId, 'debug': debug},
    );
    return ok ?? false;
  }

  @override
  Future<void> close() => _channel.invokeMethod<void>('close');

  @override
  Future<void> reportError({
    required String name,
    required String reason,
    required List<String> callStack,
    required bool fatal,
  }) {
    return _channel.invokeMethod<void>('reportError', {
      'name': name,
      'reason': reason,
      'stack': callStack.join('\n'),
      'fatal': fatal,
    });
  }
}

/// 中国大陆崩溃上报（腾讯 Bugly，0.5.1）。
///
/// - 直连官方原生 SDK（无社区 Flutter 插件），薄 MethodChannel 桥；
/// - 仅同意隐私政策后初始化（H-5/CN-05）；debug 构建与 AppId 缺失时
///   fail-closed 不采集；
/// - 上报前经 [LogRedactor] 脱敏（docs/03 可观测：不含 token/位置）；
/// - `log()` 为空实现：Bugly 无面包屑 API。
class BuglyCrashReporter implements CrashReporter {
  BuglyCrashReporter({
    BuglyBridge bridge = const MethodChannelBuglyBridge(),
    bool debugMode = kDebugMode,
    String? appId,
  })  : _bridge = bridge,
        _debugMode = debugMode,
        _appId = appId ?? BuildConfig.buglyAppId;

  final BuglyBridge _bridge;
  final bool _debugMode;
  final String _appId;

  bool _enabled = false;

  @override
  bool get enabled => _enabled;

  @override
  Future<void> initialize() async {
    if (_debugMode || _appId.isEmpty) {
      _enabled = false;
      return;
    }
    try {
      _enabled = await _bridge.init(_appId, false);
    } on Object {
      // 桥接失败（原生侧异常/未实现）降级 noop，不阻断启动。
      _enabled = false;
    }
  }

  @override
  Future<void> disable() async {
    _enabled = false;
    try {
      await _bridge.close();
    } on Object {
      // iOS 无 disable API；Dart 侧已停止上报（见 BuglyReporter.swift 注释）。
    }
  }

  @override
  void recordFlutterError(FlutterErrorDetails details) {
    if (!_enabled || _debugMode) return;
    _sendError(
      name: details.exception.runtimeType.toString(),
      reason: details.exception.toString(),
      stack: details.stack?.toString() ?? '',
    );
  }

  @override
  void recordError(Object error, StackTrace? stack, {bool fatal = false}) {
    if (!_enabled || _debugMode) return;
    _sendError(
      name: error.runtimeType.toString(),
      reason: error.toString(),
      stack: stack?.toString() ?? '',
      fatal: fatal,
    );
  }

  void _sendError({
    required String name,
    required String reason,
    required String stack,
    bool fatal = false,
  }) {
    // docs/03 可观测：不含 token/位置 —— 先脱敏再过桥；失败静默（上报不抛）。
    unawaited(() async {
      try {
        await _bridge.reportError(
          name: LogRedactor.redact(name),
          reason: LogRedactor.redact(reason),
          callStack: LogRedactor.redact(stack).split('\n'),
          fatal: fatal,
        );
      } on Object {
        // 上报失败不影响应用运行。
      }
    }());
  }

  @override
  Future<void> log(String message) async {
    // Bugly 无面包屑 API，空实现以满足 CrashReporter 接口。
  }
}

abstract final class CrashReporterFactory {
  /// 创建实现但**不初始化**（H-5：初始化推迟到隐私同意之后）。
  ///
  /// 关键点：Firebase 未配置（缺 google-services.json /
  /// GoogleService-Info.plist）时不能阻断启动，失败时降级为 noop；
  /// Bugly AppId 缺失时 fail-closed 走 Noop。
  ///
  /// [reporter]/[appId] 仅供测试注入，生产取 BuildConfig。
  static CrashReporter preparePending({String? reporter, String? appId}) {
    final kind = reporter ?? BuildConfig.crashReporter;
    final id = appId ?? BuildConfig.buglyAppId;
    switch (kind) {
      case 'bugly':
        if (id.isEmpty) return const NoopCrashReporter();
        return BuglyCrashReporter(appId: id);
      case 'firebase':
        return FirebaseCrashReporter();
      default:
        return const NoopCrashReporter();
    }
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
