import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/router.dart';
import '../../../app/widgets/common.dart';
import '../../../core/network/messaging_client.dart';
import '../../../domain/entities/models.dart';
import '../../../l10n/app_localizations.dart';
import '../../commands/application/command_center.dart';
import '../../friends/application/friends_controller.dart';
import 'event_visual.dart';

/// 前台横幅内容（sealed：新增来源时扩展子类型）。
sealed class AppBannerData {
  const AppBannerData(this.id);

  /// 去重键：同一事件 / 同一确认在短窗口内只弹一次。
  final Object id;
}

/// 事件提醒（自动消失，点击进详情）。
class EventBannerData extends AppBannerData {
  // id 依赖 event.id 插值，无法 const。
  EventBannerData({required this.event, this.deviceName})
      : super('event:${event.id}');

  final DeviceEvent event;
  final String? deviceName;
}

/// 高风险远程指令二次确认（DEV-06：factoryReset，常驻直至用户操作）。
class FactoryResetBannerData extends AppBannerData {
  const FactoryResetBannerData() : super('command:factoryReset');
}

/// 好友申请横幅（好友体系；常驻直至用户接受/拒绝）。
class FriendInviteBannerData extends AppBannerData {
  // id 依赖 invite 字段插值，无法 const。
  FriendInviteBannerData(this.invite) : super('invite:${invite.fromUniqueId}');

  final FriendInvite invite;
}

/// 应用内横幅控制器（EVT-06）。
///
/// 数据源（由 app.dart 注入）：
/// - WebSocket 实时事件（eventsFeedProvider 的新增项）；
/// - 推送事件（PushRouter.onEventBanner）；
/// - 远程指令需要确认时的回调。
class EventBannerController extends Notifier<AppBannerData?> {
  static const _autoDismiss = Duration(seconds: 4);
  static const _recentLimit = 32;

  final Set<Object> _recent = <Object>{};
  Timer? _timer;

  @override
  AppBannerData? build() {
    ref.onDispose(_cancelTimer);
    return null;
  }

  /// 实时事件横幅。状态类事件（上下线/未知设备）噪音大，
  /// 设备列表已有状态展示，不弹横幅。
  void showEvent(DeviceEvent event, {String? deviceName}) {
    switch (event.type) {
      case 'deviceOnline':
      case 'deviceOffline':
      case 'deviceUnknown':
        return;
    }
    _show(EventBannerData(event: event, deviceName: deviceName));
  }

  void showFactoryResetConfirm() => _show(const FactoryResetBannerData());

  void showFriendInvite(FriendInvite invite) =>
      _show(FriendInviteBannerData(invite));

  void _show(AppBannerData data) {
    if (!_recent.add(data.id)) return;
    if (_recent.length > _recentLimit) _recent.remove(_recent.first);
    _cancelTimer();
    if (data is! FactoryResetBannerData && data is! FriendInviteBannerData) {
      // 确认/邀请类横幅常驻；事件类自动消失。
      _timer = Timer(_autoDismiss, () {
        if (state?.id == data.id) state = null;
      });
    }
    state = data;
  }

  void dismiss() {
    _cancelTimer();
    state = null;
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }
}

final eventBannerProvider =
    NotifierProvider<EventBannerController, AppBannerData?>(
  EventBannerController.new,
);

/// 顶部横幅宿主：挂在 MaterialApp.builder 的 Stack 顶层（app.dart）。
class EventBannerHost extends ConsumerWidget {
  const EventBannerHost({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final banner = ref.watch(eventBannerProvider);
    if (banner == null) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final notifier = ref.read(eventBannerProvider.notifier);

    final Widget content;
    switch (banner) {
      case EventBannerData(:final event, :final deviceName):
        final (icon, color, label) = eventVisual(context, l10n, event.type);
        content = _BannerCard(
          icon: Icon(icon, color: color),
          title: label,
          subtitle: deviceName,
          time: event.eventTime,
          onTap: () {
            notifier.dismiss();
            ref.read(appRouterProvider).push('/event/${event.id}');
          },
          onDismiss: notifier.dismiss,
        );
      case FactoryResetBannerData():
        content = _BannerCard(
          icon: Icon(Icons.warning_amber, color: theme.colorScheme.error),
          title: l10n.commandIncomingFactoryResetTitle,
          subtitle: l10n.commandIncomingFactoryResetBody,
          confirmLabel: l10n.commonConfirm,
          cancelLabel: l10n.commonCancel,
          onConfirm: () async {
            notifier.dismiss();
            await ref.read(commandCenterProvider).factoryResetConfirmed();
          },
          onCancel: notifier.dismiss,
          onDismiss: notifier.dismiss,
        );
      case FriendInviteBannerData(:final invite):
        final name = (invite.fromName?.isNotEmpty ?? false)
            ? invite.fromName!
            : invite.fromUniqueId;
        content = _BannerCard(
          icon: Icon(Icons.group_add, color: theme.colorScheme.primary),
          title: l10n.friendsInviteBannerTitle,
          subtitle: l10n.friendsInviteBannerBody(name, invite.fromUniqueId),
          confirmLabel: l10n.friendsAccept,
          cancelLabel: l10n.commonCancel,
          onConfirm: () async {
            notifier.dismiss();
            await ref.read(friendsControllerProvider.notifier).acceptInvite();
          },
          onCancel: () async {
            notifier.dismiss();
            await ref.read(friendsControllerProvider.notifier).rejectInvite();
          },
          onDismiss: notifier.dismiss,
        );
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(12),
          color: theme.colorScheme.surfaceContainerHighest,
          child: content,
        ),
      ),
    );
  }
}

class _BannerCard extends StatelessWidget {
  const _BannerCard({
    required this.icon,
    required this.title,
    this.subtitle,
    this.time,
    this.onTap,
    this.confirmLabel,
    this.cancelLabel,
    this.onConfirm,
    this.onCancel,
    required this.onDismiss,
  });

  final Widget icon;
  final String title;
  final String? subtitle;
  final DateTime? time;
  final VoidCallback? onTap;
  final String? confirmLabel;
  final String? cancelLabel;
  final VoidCallback? onConfirm;
  final VoidCallback? onCancel;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
        child: Row(
          children: [
            icon,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty)
                    Text(
                      subtitle!,
                      style: theme.textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  if (time != null)
                    Text(
                      relativeTime(
                        l10n.timeJustNow,
                        l10n.timeSecondsAgo,
                        l10n.timeMinutesAgo,
                        l10n.timeHoursAgo,
                        l10n.timeDaysAgo,
                        time,
                        DateTime.now(),
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            if (confirmLabel != null && cancelLabel != null) ...[
              TextButton(onPressed: onCancel, child: Text(cancelLabel!)),
              FilledButton(onPressed: onConfirm, child: Text(confirmLabel!)),
            ],
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              tooltip: l10n.commonClose,
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}
