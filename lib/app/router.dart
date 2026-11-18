import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/application/session_controller.dart';
import '../features/auth/presentation/app_lock_screen.dart';
import '../features/auth/presentation/login_screen.dart';
import '../features/devices/presentation/device_detail_screen.dart';
import '../features/diagnostics/presentation/battery_guide_screen.dart';
import '../features/diagnostics/presentation/diagnostics_screen.dart';
import '../features/friends/presentation/friends_screen.dart';
import '../features/server/application/server_profile_controller.dart';
import '../features/devices/presentation/devices_screen.dart';
import '../features/events/presentation/event_detail_screen.dart';
import '../features/events/presentation/events_screen.dart';
import '../features/history/presentation/history_screen.dart';
import '../features/map/presentation/map_screen.dart';
import '../features/onboarding/presentation/mode_select_screen.dart';
import '../features/onboarding/presentation/permission_wizard_screen.dart';
import '../features/onboarding/presentation/privacy_gate_screen.dart';
import '../features/server/presentation/server_setup_screen.dart';
import '../features/settings/application/settings_controller.dart';
import '../features/settings/presentation/about_screen.dart';
import '../features/settings/presentation/notification_rules_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/tracking/presentation/tracking_screen.dart';
import '../features/tracking/presentation/tracking_settings_screen.dart';
import 'shell.dart';
import 'splash_screen.dart';

/// 根导航 Key（推送/深链全屏跳转用）。
final rootNavigatorKey = GlobalKey<NavigatorState>();

/// 路由表（docs/03 §5）与守卫：
///
/// 1. 未同意隐私 → /privacy（CN-05：同意前不初始化第三方 SDK）；
/// 2. 无服务器档案 → /server；
/// 3. 需要登录但无会话 → /login；
/// 4. 已认证但未解锁 → /lock（生物识别）；
/// 5. 推送冷启动意图在会话恢复后消费（PushRouter）。
final appRouterProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier(0);

  // 会话 / 设置变化时触发 redirect 重算。
  ref.listen(sessionControllerProvider, (_, _) => refresh.value++);
  ref.listen(settingsProvider, (_, _) => refresh.value++);
  ref.listen(serverProfileControllerProvider, (_, _) => refresh.value++);
  ref.onDispose(refresh.dispose);

  final router = GoRouter(
    initialLocation: '/',
    navigatorKey: rootNavigatorKey,
    refreshListenable: refresh,
    redirect: (context, state) {
      final settings = ref.read(settingsProvider);
      final session = ref.read(sessionControllerProvider).valueOrNull;
      final serverState =
          ref.read(serverProfileControllerProvider).valueOrNull;
      final path = state.matchedLocation;

      // 1) 隐私门（同意过且为当前政策版本；政策升级自动失效）。
      if (!settings.privacyGatePassed) {
        return path == '/privacy' ? null : '/privacy';
      }

      final hasServer = serverState?.activeProfile != null ||
          session?.profile != null;
      final authenticated = session?.isAuthenticated ?? false;
      final readOnly = session?.readOnly ?? false;
      final restoring = session == null || session.phase == SessionPhase.restoring;

      // 2) 启动决策：会话恢复期间停在 splash。
      if (path == '/') {
        if (restoring) return null;
        if (!hasServer) return '/server';
        if (!authenticated && !readOnly) return '/login';
        return '/map';
      }

      // 3) 需要服务器的页面。
      final needsServer = path.startsWith('/map') ||
          path.startsWith('/devices') ||
          path.startsWith('/friends') ||
          path.startsWith('/events') ||
          path.startsWith('/tracking') ||
          path.startsWith('/device/') ||
          path.startsWith('/event/') ||
          path.startsWith('/history');
      if (needsServer && !hasServer && path != '/server') {
        return '/server';
      }
      if (needsServer && !authenticated && !readOnly && path != '/login') {
        return '/login';
      }

      // 4) 生物识别锁。
      if (authenticated && !session!.unlocked && path != '/lock') {
        return '/lock';
      }

      return null;
    },
    routes: [
      GoRoute(path: '/', builder: (context, state) => const SplashScreen()),
      GoRoute(
        path: '/privacy',
        builder: (context, state) => const PrivacyGateScreen(),
      ),
      GoRoute(
        path: '/server',
        builder: (context, state) => ServerSetupScreen(
          initialImportUrl: state.uri.queryParameters['url'],
        ),
      ),
      GoRoute(
        path: '/login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: '/lock',
        builder: (context, state) => const AppLockScreen(),
      ),
      GoRoute(
        path: '/onboarding/mode',
        builder: (context, state) => const ModeSelectScreen(),
      ),
      GoRoute(
        path: '/onboarding/permissions',
        builder: (context, state) => const PermissionWizardScreen(),
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => AppShell(shell: shell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/map',
                builder: (context, state) => const MapScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/devices',
                builder: (context, state) => const DevicesScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/friends',
                builder: (context, state) => const FriendsScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/events',
                builder: (context, state) => const EventsScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/tracking',
                builder: (context, state) => const TrackingScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/settings',
                builder: (context, state) => const SettingsScreen(),
              ),
            ],
          ),
        ],
      ),
      // 全屏详情页（带返回栈，从推送/深链进入）。
      GoRoute(
        path: '/device/:id',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) => DeviceDetailScreen(
          deviceId: int.tryParse(state.pathParameters['id'] ?? '') ?? 0,
        ),
      ),
      GoRoute(
        path: '/device/:id/history',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) => HistoryScreen(
          deviceId: int.tryParse(state.pathParameters['id'] ?? '') ?? 0,
        ),
      ),
      GoRoute(
        path: '/event/:id',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) => EventDetailScreen(
          eventId: int.tryParse(state.pathParameters['id'] ?? '') ?? 0,
        ),
      ),
      GoRoute(
        path: '/tracking/settings',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) => const TrackingSettingsScreen(),
      ),
      GoRoute(
        path: '/settings/notifications',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) => const NotificationRulesScreen(),
      ),
      GoRoute(
        path: '/settings/about',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) => const AboutScreen(),
      ),
      GoRoute(
        path: '/diagnostics',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) => const DiagnosticsScreen(),
      ),
      GoRoute(
        path: '/diagnostics/battery',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) => const BatteryGuideScreen(),
      ),
    ],
  );

  ref.onDispose(router.dispose);
  return router;
});

/// 深链处理（`trackerone://event/<id>`、`trackerone://server?url=...`）。
class DeepLinkHandler {
  DeepLinkHandler(this._goRouter);

  final GoRouter _goRouter;

  void handle(Uri uri) {
    if (uri.scheme != 'trackerone') return;
    switch (uri.host) {
      case 'event':
        final segments = uri.pathSegments;
        final id = segments.isEmpty ? null : int.tryParse(segments.first);
        if (id != null) _goRouter.push('/event/$id');
      case 'server':
        final url = uri.queryParameters['url'];
        if (url != null && url.isNotEmpty) {
          // 带参跳转：服务器页预填地址（此前 url 被丢弃）。
          _goRouter.push('/server?url=${Uri.encodeQueryComponent(url)}');
        }
      default:
        break;
    }
  }
}

/// 供 main() 装配 app_links（返回订阅，随 ProviderScope 生命周期取消）。
StreamSubscription<Uri>? listenAppLinks(
  Stream<Uri> uriStream,
  GoRouter router,
) {
  final handler = DeepLinkHandler(router);
  return uriStream.listen(handler.handle, onError: (Object _) {});
}
