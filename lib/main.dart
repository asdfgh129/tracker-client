import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'core/observability/crash_reporter.dart';
import 'core/observability/log_sink.dart';
import 'core/providers.dart';
import 'core/storage/data_eraser.dart';
import 'core/storage/database.dart';
import 'core/storage/preferences.dart';
import 'features/auth/application/session_controller.dart';
import 'features/settings/application/settings_controller.dart';
import 'features/tracking/application/tracking_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1) 崩溃处理。
  //
  // H-5：Firebase 只在海外包启用（CRASH_REPORTER=firebase），且必须等
  // 隐私同意后再初始化 —— 未同意前不得初始化任何第三方 SDK（CN-05）。
  // 这里只安装错误处理器并预创建实现；SDK 初始化由首次同意触发
  //（CrashReporter.initialize 在同意后才被调用）。
  final crashReporter = CrashReporterFactory.preparePending();
  installCrashHandlers(crashReporter);

  // 2) 本地基础设施：Prefs + drift 数据库 + 文件日志。
  final prefs = await SharedPreferences.getInstance();
  final logSink = FileLogSink();
  await logSink.attach();
  final database = AppDatabase.open('trackerone.db');

  // 3) 缓存保留策略（位置 7 天 / 事件 30 天）——后台清理，不阻塞启动。
  unawaited(database.purgeExpired());

  runApp(
    ProviderScope(
      overrides: [
        crashReporterProvider.overrideWithValue(crashReporter),
        prefsProvider.overrideWithValue(SharedPrefs(prefs)),
        appDatabaseProvider.overrideWithValue(database),
        // H-6：设置页与登出共用的删除实现（避免 core 反向依赖 feature）。
        logEraserProvider.overrideWithValue(DataEraser.eraseLogs),
        exportEraserProvider.overrideWithValue(DataEraser.eraseExports),
        // 撤回隐私同意 / 删除本地数据：先停止一切采集再清数据。
        // 停止跟踪失败也要继续断开连接与复位会话，否则会留下“半撤回”状态。
        privacyTeardownProvider.overrideWith(
          (ref) => () async {
            Object? stopError;
            try {
              await ref.read(trackingControllerProvider.notifier).stop();
            } on Object catch (error) {
              stopError = error;
            }
            ref.read(socketClientProvider).disconnect();
            await ref.read(sessionControllerProvider.notifier).expireSession();
            if (stopError != null) throw stopError;
          },
        ),
      ],
      child: const TrackerOneApp(),
    ),
  );
}
