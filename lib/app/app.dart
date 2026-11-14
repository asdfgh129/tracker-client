import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/auth/application/session_controller.dart';
import '../features/settings/application/settings_controller.dart';
import '../l10n/app_localizations.dart';
import '../core/push/push_router.dart';
import 'router.dart';
import 'theme.dart';

/// 应用根：主题 / 语言 / 路由 / 生命周期。
class TrackerOneApp extends ConsumerStatefulWidget {
  const TrackerOneApp({super.key});

  @override
  ConsumerState<TrackerOneApp> createState() => _TrackerOneAppState();
}

class _TrackerOneAppState extends ConsumerState<TrackerOneApp>
    with WidgetsBindingObserver {
  AppLifecycleState _last = AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 推送路由：启动即消费网关消息流（冷启动意图缓存至会话就绪）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(pushRouterProvider).start();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // WebSocket 生命周期（docs/03 §6.2：进后台断开省电，回前台立即恢复）。
    final socket = ref.read(socketClientProvider);
    switch (state) {
      case AppLifecycleState.resumed:
        if (_last == AppLifecycleState.paused ||
            _last == AppLifecycleState.hidden) {
          socket.resume();
        }
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        socket.suspend();
      case AppLifecycleState.detached:
      case AppLifecycleState.inactive:
        break;
    }
    _last = state;
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final router = ref.watch(appRouterProvider);

    return MaterialApp.router(
      title: 'TrackerOne',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: settings.themeMode,
      locale: settings.localeLanguageCode == null
          ? null
          : Locale(settings.localeLanguageCode!),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
