import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/observability/logger.dart';
import '../../../core/providers.dart';
import '../../../core/storage/database.dart';
import '../../../domain/entities/models.dart';
import '../../../domain/failures.dart';
import '../../auth/application/session_controller.dart';
import '../../devices/application/devices_controller.dart'
    show devicesControllerProvider, eventToRow, eventsFeedProvider;

/// 事件筛选（docs/02 §3.9 分段：全部/未读/告警/围栏）。
enum EventFilter { all, unread, alarms, geofences }

extension EventFilterX on EventFilter {
  bool matches(EventListItem item) {
    final type = item.event.type;
    return switch (this) {
      EventFilter.all => true,
      EventFilter.unread => !item.isRead,
      EventFilter.alarms =>
        type == 'alarm' || type == 'sos' || type == 'overspeed',
      EventFilter.geofences =>
        type == 'geofenceEnter' || type == 'geofenceExit',
    };
  }
}

/// 列表项视图：事件 + 关联设备名 + 已读状态。
class EventListItem {
  const EventListItem({required this.event, required this.isRead, this.deviceName});

  final DeviceEvent event;
  final bool isRead;
  final String? deviceName;

  int get id => event.id;
}

/// 事件状态。
class EventsState {
  const EventsState({
    this.items = const [],
    this.filter = EventFilter.all,
    this.loading = false,
    this.offline = false,
  });

  final List<EventListItem> items;
  final EventFilter filter;
  final bool loading;
  final bool offline;

  List<EventListItem> get filtered =>
      items.where((item) => filter.matches(item)).toList();

  int get unreadCount => items.where((item) => !item.isRead).length;

  /// 缓存内按 id 查找（推送/深链直达时用）。
  EventListItem? byId(int eventId) {
    for (final item in items) {
      if (item.id == eventId) return item;
    }
    return null;
  }

  EventsState copyWith({
    List<EventListItem>? items,
    EventFilter? filter,
    bool? loading,
    bool? offline,
  }) {
    return EventsState(
      items: items ?? this.items,
      filter: filter ?? this.filter,
      loading: loading ?? this.loading,
      offline: offline ?? this.offline,
    );
  }
}

/// 事件控制器（EVT-01/02/06）：
///
/// - 列表：drift 缓存（30 天保留）优先；
/// - 实时：WebSocket 事件经 devices 层落库 + eventsFeedProvider；
/// - 补拉：`/api/reports/events` 回填（推送丢失兜底，docs/09 §3.7）。
class EventsController extends AsyncNotifier<EventsState> {
  @override
  Future<EventsState> build() async {
    final session = ref.watch(sessionControllerProvider).value;
    final serverId = session?.profile?.id;
    if (session == null || !session.isAuthenticated || serverId == null) {
      return const EventsState();
    }
    ref.watch(appDatabaseProvider);

    await _reloadFromDb();

    // 实时事件（devices 层已写库，这里消费进料刷新列表）。
    ref.listen(eventsFeedProvider, (_, _) {
      unawaited(_reloadFromDb());
    });

    // 冷启动兜底：补拉最近 7 天事件。
    unawaited(backfill());

    return state.valueOrNull ?? const EventsState();
  }

  Future<void> _reloadFromDb() async {
    final session = ref.read(sessionControllerProvider).value;
    final serverId = session?.profile?.id;
    if (serverId == null) return;
    final db = ref.read(appDatabaseProvider);
    final rows = await db.eventsFor(serverId, limit: 300);
    final devicesState = ref.read(devicesControllerProvider).value;
    final nameById = {
      for (final device in devicesState?.devices ?? const <Device>[])
        device.id: device.name,
    };
    final items = [
      for (final row in rows)
        EventListItem(
          event: eventFromRow(row),
          isRead: row.read,
          deviceName: nameById[row.deviceId],
        ),
    ];
    final current = state.valueOrNull ?? const EventsState();
    state = AsyncData(current.copyWith(items: items));
  }

  /// 历史事件补拉（deviceId 为 null 时对前 10 个设备逐个拉取）。
  Future<void> backfill({int? deviceId}) async {
    final session = ref.read(sessionControllerProvider).value;
    final serverId = session?.profile?.id;
    if (session == null || serverId == null) return;
    final db = ref.read(appDatabaseProvider);
    final now = DateTime.now().toUtc();
    final from = now.subtract(const Duration(days: 7));

    state = AsyncData(
      (state.valueOrNull ?? const EventsState()).copyWith(loading: true),
    );
    try {
      final api = ref.read(sessionControllerProvider.notifier).apiFor(session);
      final targets = deviceId != null
          ? [deviceId]
          : (ref.read(devicesControllerProvider).value?.devices ?? const <Device>[])
              .take(10)
              .map((d) => d.id)
              .toList();

      // 性能 P2-c：设备间并行（限 3 并发避免瞬时打满连接池），
      // 串行 10 设备在弱网下会让冷启动补拉超过 10s。
      final collected = <DeviceEvent>[];
      const concurrency = 3;
      var cursor = 0;
      Future<Object?> worker(int _) async {
        while (cursor < targets.length) {
          final id = targets[cursor++];
          try {
            final events = await api.getEventsHistory(
              deviceId: id,
              from: from,
              to: now,
            );
            collected.addAll(events);
          } on AppFailure catch (error) {
            AppLog.w('events', 'backfill device $id failed: ${error.code ?? '-'}');
          }
        }
        return null;
      }
      await Future.wait(
        List.generate(
          concurrency < targets.length ? concurrency : targets.length,
          worker,
        ),
      );

      if (collected.isNotEmpty) {
        await db.upsertEvents(
          serverId,
          collected.map(eventToRow(serverId)).toList(),
        );
      }
      await _reloadFromDb();
      state = AsyncData(
        (state.valueOrNull ?? const EventsState()).copyWith(
          loading: false,
          offline: false,
        ),
      );
    } on AppFailure catch (error) {
      AppLog.w('events', 'backfill failed: ${error.code ?? '-'}');
      state = AsyncData(
        (state.valueOrNull ?? const EventsState()).copyWith(
          loading: false,
          offline: true,
        ),
      );
    }
  }

  Future<void> setFilter(EventFilter filter) async {
    final current = state.valueOrNull ?? const EventsState();
    state = AsyncData(current.copyWith(filter: filter));
  }

  /// 标记已读（EVT-02，左滑操作）。
  Future<void> markRead(int eventId, {bool read = true}) async {
    final session = ref.read(sessionControllerProvider).value;
    final serverId = session?.profile?.id;
    if (serverId == null) return;
    await ref
        .read(appDatabaseProvider)
        .markEventRead(serverId, eventId, read: read);
    await _reloadFromDb();
  }

  /// 单条事件获取（推送点进详情时，可能本地还没有）。
  Future<DeviceEvent?> fetchEvent(int eventId) async {
    final session = ref.read(sessionControllerProvider).value;
    final serverId = session?.profile?.id;
    if (session == null || serverId == null) return null;
    try {
      final event = await session.api().getEvent(eventId);
      if (event != null) {
        await ref
            .read(appDatabaseProvider)
            .upsertEvents(serverId, [eventToRow(serverId)(event)]);
        await _reloadFromDb();
      }
      return event;
    } on AppFailure catch (error) {
      AppLog.w('events', 'fetch event failed: ${error.code ?? '-'}');
      return null;
    }
  }

}

DeviceEvent eventFromRow(EventRow row) => DeviceEvent(
      id: row.id,
      deviceId: row.deviceId ?? 0,
      type: row.type ?? 'unknown',
      eventTime: row.eventTime == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(row.eventTime!),
      positionId: row.positionId,
      geofenceId: row.geofenceId,
      attributes: row.attributes == null
          ? const {}
          : _readAttributes(row.attributes!),
    );

Map<String, dynamic> _readAttributes(String raw) {
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map<String, dynamic> ? decoded : const {};
  } on Object {
    return const {};
  }
}

final eventsControllerProvider =
    AsyncNotifierProvider<EventsController, EventsState>(EventsController.new);
