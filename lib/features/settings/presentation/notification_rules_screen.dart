import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../events/presentation/event_visual.dart';
import '../application/notification_rules_controller.dart';

/// 通知规则子页：按事件类型开关提醒与离线推送。
///
/// 开启的规则经 `web`（在线 WebSocket）与 `webhook`（离线推送网关 → 极光）
/// 两条通道投递；关闭即删除对应规则。
class NotificationRulesScreen extends ConsumerWidget {
  const NotificationRulesScreen({super.key});

  /// 可开关的事件类型（与服务端默认规则清单一致）。
  static const _ruleTypes = <String>[
    'deviceOnline',
    'deviceOffline',
    'deviceUnknown',
    'alarm',
    'deviceOverspeed',
    'geofenceEnter',
    'geofenceExit',
    'ignitionOn',
    'ignitionOff',
    'maintenance',
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final state = ref.watch(notificationRulesProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsNotifications)),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              l10n.settingsNotificationsDesc,
              style: theme.textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: state.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('${l10n.notifLoadFailed}: $error'),
                    const SizedBox(height: 12),
                    FilledButton.tonal(
                      onPressed: () => ref.invalidate(notificationRulesProvider),
                      child: Text(l10n.commonRetry),
                    ),
                  ],
                ),
              ),
              data: (rules) {
                return ListView(
                  children: [
                    for (final type in _ruleTypes)
                      _RuleTile(
                        type: type,
                        enabled: rules.any((rule) => rule.type == type),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _RuleTile extends ConsumerStatefulWidget {
  const _RuleTile({required this.type, required this.enabled});

  final String type;
  final bool enabled;

  @override
  ConsumerState<_RuleTile> createState() => _RuleTileState();
}

class _RuleTileState extends ConsumerState<_RuleTile> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final (icon, color, label) = eventVisual(context, l10n, widget.type);

    return SwitchListTile(
      secondary: Icon(icon, color: color),
      title: Text(label),
      value: widget.enabled,
      onChanged: _busy
          ? null
          : (value) async {
              setState(() => _busy = true);
              final messenger = ScaffoldMessenger.of(context);
              try {
                await ref
                    .read(notificationRulesProvider.notifier)
                    .setEnabled(widget.type, enabled: value);
              } on Object catch (error) {
                messenger.showSnackBar(
                  SnackBar(content: Text('${l10n.notifSaveFailed}: $error')),
                );
              } finally {
                if (mounted) setState(() => _busy = false);
              }
            },
      subtitle: _busy
          ? const SizedBox(
              height: 12,
              width: 12,
              child: LinearProgressIndicator(minHeight: 2),
            )
          : null,
      // 主题样式保持一致。
      controlAffinity: ListTileControlAffinity.trailing,
    );
  }
}
