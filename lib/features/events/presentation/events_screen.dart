import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/widgets/common.dart';
import '../../../l10n/app_localizations.dart';
import '../application/events_controller.dart';
import 'event_visual.dart';

/// 事件列表（EVT-01/02，docs/02 §3.9：分段筛选、左滑已读）。
class EventsScreen extends ConsumerStatefulWidget {
  const EventsScreen({super.key});

  @override
  ConsumerState<EventsScreen> createState() => _EventsScreenState();
}

class _EventsScreenState extends ConsumerState<EventsScreen> with WidgetsBindingObserver {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // 性能 P2-e：后台时暂停 30s 相对时间 ticker（避免不可见页持续唤醒 isolate）。
    WidgetsBinding.instance.addObserver(this);
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _ticker ??= Timer.periodic(const Duration(seconds: 30), (_) {
        if (mounted) setState(() {});
      });
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final state =
        ref.watch(eventsControllerProvider).valueOrNull ?? const EventsState();

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.eventsTitle),
        actions: [
          if (state.unreadCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Badge(
                  label: Text('${state.unreadCount}'),
                  child: const Icon(Icons.notifications_outlined),
                ),
              ),
            ),
          IconButton(
            tooltip: l10n.commonRefresh,
            icon: const Icon(Icons.refresh),
            onPressed: () =>
                ref.read(eventsControllerProvider.notifier).backfill(),
          ),
        ],
      ),
      body: Column(
        children: [
          // 分段筛选。
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                for (final filter in EventFilter.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(_filterLabel(l10n, filter)),
                      selected: state.filter == filter,
                      onSelected: (_) => ref
                          .read(eventsControllerProvider.notifier)
                          .setFilter(filter),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: state.loading && state.items.isEmpty
                ? const ListSkeleton()
                : state.items.isEmpty
                    ? EmptyState(
                        icon: Icons.notifications_none,
                        title: l10n.eventsEmpty,
                        subtitle: l10n.eventsEmptyHint,
                      )
                    : RefreshIndicator(
                        onRefresh: () => ref
                            .read(eventsControllerProvider.notifier)
                            .backfill(),
                        child: ListView.builder(
                          itemCount: state.items.length,
                          itemBuilder: (context, index) {
                            final item = state.items[index];
                            return Dismissible(
                              key: ValueKey('event-${item.id}'),
                              direction: DismissDirection.startToEnd,
                              background: Container(
                                color: theme.colorScheme.primaryContainer,
                                alignment: Alignment.centerLeft,
                                padding: const EdgeInsets.only(left: 24),
                                child: Icon(
                                  item.isRead
                                      ? Icons.mark_email_unread_outlined
                                      : Icons.mark_email_read_outlined,
                                  color:
                                      theme.colorScheme.onPrimaryContainer,
                                ),
                              ),
                              onDismissed: (_) {
                                ref
                                    .read(eventsControllerProvider.notifier)
                                    .markRead(item.id, read: !item.isRead);
                              },
                              child: _EventTile(
                                item: item,
                                now: DateTime.now(),
                              ),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  String _filterLabel(AppLocalizations l10n, EventFilter filter) =>
      switch (filter) {
        EventFilter.all => l10n.eventsFilterAll,
        EventFilter.unread => l10n.eventsFilterUnread,
        EventFilter.alarms => l10n.eventsFilterAlarms,
        EventFilter.geofences => l10n.eventsFilterGeofences,
      };
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.item, required this.now});

  final EventListItem item;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final (icon, color, label) = eventVisual(context, l10n, item.event.type);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Row(
          children: [
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
            ),
            if (!item.isRead)
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
        subtitle: Wrap(
          spacing: 12,
          children: [
            if (item.deviceName != null) Text(item.deviceName!),
            Text(
              relativeTime(
                l10n.timeJustNow,
                l10n.timeSecondsAgo,
                l10n.timeMinutesAgo,
                l10n.timeHoursAgo,
                l10n.timeDaysAgo,
                item.event.eventTime,
                now,
              ),
            ),
          ],
        ),
        trailing: const Icon(Icons.chevron_right, size: 18),
        onTap: () => context.push('/event/${item.id}'),
      ),
    );
  }
}
