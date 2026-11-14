import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/observability/logger.dart';
import '../../../domain/failures.dart';
import '../../auth/application/session_controller.dart';

/// 通知规则（服务端 tc_notifications 的用户可见视图）。
class NotificationRule {
  const NotificationRule({
    required this.id,
    required this.type,
    required this.always,
    this.notificators,
  });

  final int id;
  final String type;
  final bool always;
  final String? notificators;

  static NotificationRule? fromMap(Map<String, dynamic> json) {
    final id = json['id'];
    final type = json['type']?.toString();
    if (id is! int || type == null) return null;
    return NotificationRule(
      id: id,
      type: type,
      always: json['always'] == true,
      notificators: json['notificators']?.toString(),
    );
  }
}

/// 通知规则开关的默认投递通道：web = 在线 WebSocket，webhook = 离线推送网关。
const kDefaultNotificationNotificators = 'web,webhook';

/// 通知规则控制器：读取/开关事件类型的规则。
///
/// 背景：服务端仅为**自注册**用户自动创建默认规则；管理员创建的用户
/// 没有规则 → 离线推送（webhook → 极光）收不到。此控制器让用户自助开关。
class NotificationRulesController
    extends AsyncNotifier<List<NotificationRule>> {
  @override
  Future<List<NotificationRule>> build() async {
    final session = ref.watch(sessionControllerProvider).valueOrNull;
    if (session == null || !session.isAuthenticated) {
      return const <NotificationRule>[];
    }
    final api = session.api();
    try {
      final items = await api.getNotifications();
      return [
        for (final item in items)
          if (NotificationRule.fromMap(item) case final rule?) rule,
      ];
    } on AppFailure catch (error) {
      AppLog.w('notifications', 'load failed: ${error.code ?? '-'}');
      rethrow;
    }
  }

  /// 开启（创建规则）或关闭（删除规则）某类事件的通知。
  Future<void> setEnabled(String type, {required bool enabled}) async {
    final session = ref.watch(sessionControllerProvider).valueOrNull;
    if (session == null || !session.isAuthenticated) {
      throw const UnauthorizedFailure();
    }
    final api = session.api();
    final current = state.valueOrNull ?? const <NotificationRule>[];
    if (enabled) {
      if (current.any((rule) => rule.type == type)) return;
      final created = await api.createNotificationRule(
        type: type,
        always: true,
        notificators: kDefaultNotificationNotificators,
      );
      final rule = NotificationRule.fromMap(created);
      if (rule != null) {
        state = AsyncData([...current, rule]);
      }
    } else {
      final existing = current.where((rule) => rule.type == type).toList();
      for (final rule in existing) {
        await api.deleteNotificationRule(rule.id);
      }
      state = AsyncData(
        current.where((rule) => rule.type != type).toList(),
      );
    }
  }
}

final notificationRulesProvider = AsyncNotifierProvider<
    NotificationRulesController, List<NotificationRule>>(
  NotificationRulesController.new,
);
