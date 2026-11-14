import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/network/messaging_client.dart';
import '../core/observability/logger.dart';
import '../core/push/push_router.dart';
import '../features/auth/application/session_controller.dart';
import '../features/commands/application/command_center.dart';
import '../features/commands/application/command_outbox.dart';
import '../features/devices/application/devices_controller.dart';
import '../features/events/presentation/event_banner.dart';
import '../features/friends/application/friends_controller.dart';
import '../features/settings/application/settings_controller.dart';
import '../features/tracking/application/tracking_controller.dart';
import '../l10n/app_localizations.dart';
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
  StreamSubscription<Uri>? _deepLinks;

  /// 会话就绪信号已发给 PushRouter（避免重复 consumePending）。
  bool _sessionReadyNotified = false;

  /// 已弹过对话框的定位请求 id（好友定位请求，避免重复弹窗）。
  int? _shownLocationRequestId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _wirePushRouter();
      _wireDeepLinks();
    });
  }

  /// A1 接线：PushRouter 的三个回调此前一直悬空——消息解析后不会产生
  /// 导航 / 指令 / 横幅效果。此处注入后 push.start() 才真正闭环。
  void _wirePushRouter() {
    final pushRouter = ref.read(pushRouterProvider);
    pushRouter.onNavigate = (intent) {
      final router = ref.read(appRouterProvider);
      final eventId = intent.eventId;
      if (eventId != null) {
        router.push('/event/$eventId');
      } else if (intent.deviceId != null) {
        router.push('/device/${intent.deviceId}');
      }
    };
    pushRouter.onCommand = (message) async {
      final outcome =
          await ref.read(commandCenterProvider).handleIncoming(message);
      if (outcome == RemoteCommandOutcome.needsConfirmation) {
        // factoryReset：横幅二次确认（DEV-06）。
        ref.read(eventBannerProvider.notifier).showFactoryResetConfirm();
      }
      // needsConfirmation 已转 UI 确认，视为已处理（不重投）。
      return outcome == RemoteCommandOutcome.executed ||
          outcome == RemoteCommandOutcome.needsConfirmation;
    };
    pushRouter.onEventBanner = (event) {
      ref.read(eventBannerProvider.notifier).showEvent(event);
    };
    // 回调就绪后再开始消费网关消息流（冷启动意图缓存至会话就绪）。
    pushRouter.start();
  }

  /// A1 接线：`trackerone://` 深链（此前 listenAppLinks 从未被调用）。
  void _wireDeepLinks() {
    final links = AppLinks();
    final router = ref.read(appRouterProvider);
    _deepLinks = listenAppLinks(links.uriLinkStream, router);
    links.getInitialLink().then((uri) {
      if (uri != null) DeepLinkHandler(router).handle(uri);
    }).catchError((Object error) {
      AppLog.w('deeplink', 'initial link failed: $error');
    });
  }

  void _onSessionChanged(
    AsyncValue<SessionState>? previous,
    AsyncValue<SessionState> next,
  ) {
    final authenticated = next.valueOrNull?.isAuthenticated ?? false;
    final pushRouter = ref.read(pushRouterProvider);
    if (authenticated && !_sessionReadyNotified) {
      _sessionReadyNotified = true;
      pushRouter.setSessionReady(true);
      // 放行冷启动/未登录期间缓存的推送意图（docs/03 §15.4）。
      pushRouter.consumePending();
      // 会话就绪：补发离线期间积压的指令（指令发件箱）。
      unawaited(ref.read(commandOutboxProvider).flush());
    } else if (!authenticated && _sessionReadyNotified) {
      _sessionReadyNotified = false;
      pushRouter.setSessionReady(false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // WebSocket 生命周期（docs/03 §6.2：进后台断开省电，回前台立即恢复）。
    final socket = ref.read(socketClientProvider);
    final messaging = ref.read(messagingClientProvider);
    // 跟踪运行中（前台服务存活）时保持好友通道，否则后台断开省电。
    final trackingActive = switch (
        ref.read(trackingControllerProvider).valueOrNull) {
      TrackingStarting() || TrackingRunning() || TrackingLimited() => true,
      _ => false,
    };
    switch (state) {
      case AppLifecycleState.resumed:
        if (_last == AppLifecycleState.paused ||
            _last == AppLifecycleState.hidden) {
          socket.resume();
          messaging.resume();
          // 回前台是网络恢复的常见时机：补发离线指令。
          unawaited(ref.read(commandOutboxProvider).flush());
        }
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        socket.suspend();
        if (trackingActive) {
          messaging.resume();
        } else {
          messaging.suspend();
        }
      case AppLifecycleState.detached:
      case AppLifecycleState.inactive:
        break;
    }
    _last = state;
  }

  /// 好友实时定位请求 → 全局弹窗（同意 → 分享本机位置；拒绝 → declined）。
  void _maybeShowLocationRequestDialog(IncomingLocationRequest? request) {
    if (request == null) return;
    if (_shownLocationRequestId == request.requestId) return;
    _shownLocationRequestId = request.requestId;
    final context = rootNavigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    final l10n = AppLocalizations.of(context);
    final name = (request.fromName?.isNotEmpty ?? false)
        ? request.fromName!
        : request.fromUniqueId;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.friendsRequestTitle),
        content: Text(l10n.friendsRequestBody(name)),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              unawaited(
                ref
                    .read(friendsControllerProvider.notifier)
                    .respondRequest(accept: false),
              );
            },
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              unawaited(
                ref
                    .read(friendsControllerProvider.notifier)
                    .respondRequest(accept: true),
              );
            },
            child: Text(l10n.friendsRequestShare),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final router = ref.watch(appRouterProvider);

    // 会话就绪 → 放行推送冷启动意图。
    ref.listen(sessionControllerProvider, _onSessionChanged);

    // WS 实时事件 → 前台横幅（EVT-06；推送路径经 PushRouter.onEventBanner）。
    ref.listen(eventsFeedProvider, (previous, next) {
      final prevCount = previous?.length ?? 0;
      if (next.length <= prevCount) return;
      final devices = ref.read(devicesControllerProvider).valueOrNull;
      for (final event in next.take(next.length - prevCount)) {
        ref.read(eventBannerProvider.notifier).showEvent(
              event,
              deviceName: devices?.deviceById(event.deviceId)?.name,
            );
      }
    });

    // 好友体系：实时邀请 → 横幅；定位请求 → 全局弹窗。
    ref.listen(friendsControllerProvider, (previous, next) {
      final invite = next.pendingInvite;
      if (invite != null && invite != previous?.pendingInvite) {
        ref.read(eventBannerProvider.notifier).showFriendInvite(invite);
      }
      _maybeShowLocationRequestDialog(next.pendingRequest);
    });

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
      // 前台事件横幅 / 高风险指令确认（A3）：挂在导航之上的全局宿主。
      builder: (context, child) => Stack(
        children: [
          child!,
          const Positioned(top: 0, left: 0, right: 0, child: EventBannerHost()),
        ],
      ),
      routerConfig: router,
    );
  }

  @override
  void dispose() {
    _deepLinks?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
