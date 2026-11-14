import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/models.dart';
import '../observability/logger.dart';
import 'push_gateway.dart';
import 'push_service.dart';

/// 待消费的推送意图（冷启动 / 未登录时缓存，登录后消费，docs/03 §15.4）。
class PendingPushIntent {
  const PendingPushIntent({
    this.eventId,
    this.deviceId,
    this.command,
    this.friendInvite = false,
  });

  final int? eventId;
  final int? deviceId;
  final String? command;

  /// 好友邀请唤醒：无 eventId/deviceId 语义（deviceId 是本机设备），
  /// 落点由 app 层决定（好友页 + 刷新列表）。
  final bool friendInvite;

  bool get isEmpty =>
      eventId == null && deviceId == null && command == null && !friendInvite;
}

/// 推送路由（EVT-04、DEV-06）：
///
/// - 事件通知：前台 → 应用内横幅（[onEventBanner]）；点击 → `/event/:id`；
/// - 远程指令：交 [CommandCenter]（通过回调注入避免循环依赖）；
/// - 未登录 / 冷启动：先缓存，会话恢复后由 [consumePending] 放行。
class PushRouter {
  PushRouter(this._ref);

  final Ref _ref;

  /// 点击事件通知时的跳转回调（由 UI 层注入，避免 push 层依赖 router）。
  void Function(PendingPushIntent intent)? onNavigate;

  /// 应用内横幅回调（前台不弹系统通知，docs/01 §3.7）。
  void Function(DeviceEvent event)? onEventBanner;

  /// 远程指令处理器（CommandCenter.handleIncoming）。
  Future<bool> Function(PushMessage message)? onCommand;

  PendingPushIntent? _pending;
  StreamSubscription<PushMessage>? _subscription;
  bool _sessionReady = false;

  /// 会话恢复完成后由 app 层调用；此后事件意图直接导航而不是缓存。
  void setSessionReady(bool ready) => _sessionReady = ready;

  /// 应用启动即调用：开始消费网关消息流。
  void start() {
    _subscription?.cancel();
    _subscription = _ref.read(pushServiceProvider).messages.listen(_handle);
    unawaited(_consumeInitial());
  }

  Future<void> _consumeInitial() async {
    final initial = await _ref.read(pushServiceProvider).takeInitialMessage();
    if (initial != null) _handle(initial);
  }

  void _handle(PushMessage message) {
    if (message.isCommand) {
      unawaited(_handleCommand(message));
      return;
    }
    if (message.isFriendInvite) {
      // 好友邀请离线唤醒（CN-1.1）：服务端 payload 只有 event.type、
      // 没有 event.id，此前因缺 eventId 被静默忽略。申请本身已持久化
      // 为 pending_in，这里负责把用户带到好友页闭环。
      final intent = const PendingPushIntent(friendInvite: true);
      if (_sessionReady) {
        onNavigate?.call(intent);
      } else {
        _pending = intent;
        AppLog.i('push', 'friend invite intent cached');
      }
      return;
    }
    final eventId = message.eventId;
    if (eventId == null) {
      AppLog.d('push', 'message without eventId ignored');
      return;
    }
    final deviceIdRaw = message.data['deviceId'];
    final intent = PendingPushIntent(
      eventId: eventId,
      deviceId: deviceIdRaw is int
          ? deviceIdRaw
          : int.tryParse(deviceIdRaw?.toString() ?? ''),
    );
    if (_sessionReady) {
      onNavigate?.call(intent);
    } else {
      // 未登录：缓存意图，登录后继续跳转（docs/04 §7.4）。
      _pending = intent;
      AppLog.i('push', 'intent cached (eventId=$eventId)');
    }
  }

  Future<void> _handleCommand(PushMessage message) async {
    final handler = onCommand;
    if (handler == null) {
      _pending = PendingPushIntent(command: message.command);
      return;
    }
    final executed = await handler(message);
    if (!executed) {
      _pending = PendingPushIntent(command: message.command);
    }
  }

  /// 会话恢复完成 / 登录完成后调用：放行缓存的意图。
  PendingPushIntent? consumePending() {
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isEmpty) {
      if (pending.command != null) {
        // 指令在登录后重新投递给处理器。
        unawaited(
          onCommand?.call(
                PushMessage(command: pending.command),
              ) ??
              Future<bool>.value(false),
        );
        return null;
      }
      onNavigate?.call(pending);
      return pending;
    }
    return null;
  }

  /// WebSocket 实时事件的前台横幅（EVT-06）。
  void showInAppBanner(DeviceEvent event) => onEventBanner?.call(event);

  Future<void> dispose() => _subscription?.cancel() ?? Future<void>.value();
}

/// 推送路由单例。
final pushRouterProvider = Provider<PushRouter>((ref) {
  final router = PushRouter(ref);
  ref.onDispose(router.dispose);
  return router;
});
