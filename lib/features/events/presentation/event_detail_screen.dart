import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/widgets/common.dart';
import '../../../l10n/app_localizations.dart';
import '../application/events_controller.dart';

/// 事件详情（EVT-04 点击直达：显示事件信息 + 在地图查看）。
class EventDetailScreen extends ConsumerStatefulWidget {
  const EventDetailScreen({required this.eventId, super.key});

  final int eventId;

  @override
  ConsumerState<EventDetailScreen> createState() => _EventDetailScreenState();
}

class _EventDetailScreenState extends ConsumerState<EventDetailScreen> {
  @override
  void initState() {
    super.initState();
    // 本地缓存没有时从服务端拉取（推送冷启动场景）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = ref.read(eventsControllerProvider.notifier);
      final cached = ref.read(eventsControllerProvider).valueOrNull?.byId(widget.eventId);
      if (cached == null) {
        controller.fetchEvent(widget.eventId);
      } else {
        ref
            .read(eventsControllerProvider.notifier)
            .markRead(widget.eventId);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final controller = ref.watch(eventsControllerProvider);
    final item = controller.valueOrNull?.byId(widget.eventId);

    if (item == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.eventDetailTitle)),
        body: controller.valueOrNull?.loading ?? false
            ? const Center(child: CircularProgressIndicator())
            : EmptyState(
                icon: Icons.event_busy,
                title: l10n.eventNotFound,
              ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.eventDetailTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.event.type, style: theme.textTheme.titleLarge),
                  const SizedBox(height: 8),
                  if (item.deviceName != null)
                    Text(item.deviceName!, style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 8),
                  Text(
                    '${l10n.eventTime}: '
                    '${item.event.eventTime?.toLocal().toString() ?? '-'}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (item.event.deviceId != 0)
            FilledButton.icon(
              onPressed: () {
                ref
                    .read(eventsControllerProvider.notifier)
                    .markRead(item.id);
                context.push('/device/${item.event.deviceId}');
              },
              icon: const Icon(Icons.map),
              label: Text(l10n.eventDetailOpenLocation),
            ),
        ],
      ),
    );
  }
}
