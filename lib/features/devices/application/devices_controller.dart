import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/map/geo_point.dart';
import '../../../core/network/socket_client.dart';
import '../../../core/observability/logger.dart';
import '../../../core/providers.dart';
import '../../../core/storage/database.dart';
import '../../../domain/entities/models.dart';
import '../../../domain/failures.dart';
import '../../auth/application/session_controller.dart';
import '../../map/application/map_controller.dart';

/// 设备实时视图（docs/03 §15.2）。
///
/// 数据流：drift 缓存先出（冷启动不白屏）→ REST 快照刷新 →
/// WebSocket 增量合并（10 秒内可见，docs/01 §3.5 验收）。
class DevicesState {
  const DevicesState({
    this.devices = const [],
    this.positions = const {},
    this.socketStatus = SocketStatus.disconnected,
    this.offline = false,
    this.lastRefresh,
  });

  final List<Device> devices;
  final Map<int, Position> positions;
  final SocketStatus socketStatus;

  /// REST 快照失败但缓存可用时为 true（顶部离线横幅）。
  final bool offline;
  final DateTime? lastRefresh;

  int get onlineCount => devices.where((d) => d.isOnline).length;

  Device? deviceById(int id) {
    for (final device in devices) {
      if (device.id == id) return device;
    }
    return null;
  }

  Position? positionOf(int deviceId) => positions[deviceId];

  DevicesState copyWith({
    List<Device>? devices,
    Map<int, Position>? positions,
    SocketStatus? socketStatus,
    bool? offline,
    DateTime? lastRefresh,
  }) {
    return DevicesState(
      devices: devices ?? this.devices,
      positions: positions ?? this.positions,
      socketStatus: socketStatus ?? this.socketStatus,
      offline: offline ?? this.offline,
      lastRefresh: lastRefresh ?? this.lastRefresh,
    );
  }
}

/// 设备控制器：缓存 + 快照 + WebSocket 三路数据合并。
class DevicesController extends AsyncNotifier<DevicesState> {
  StreamSubscription<SocketSnapshot>? _snapshots;
  StreamSubscription<SocketStatus>? _status;

  @override
  Future<DevicesState> build() async {
    final session = ref.watch(sessionControllerProvider).value;
    final profile = session?.profile;
    final serverId = profile?.id;
    if (session == null || !session.isAuthenticated || serverId == null) {
      return const DevicesState();
    }

    final db = ref.watch(appDatabaseProvider);

    // 1) 先读缓存（离线优先，docs/03 §6.3）。
    final cachedDevices = await db.devicesFor(serverId);
    final cachedPositions = await db.latestPositions(serverId);
    final cached = DevicesState(
      devices: cachedDevices.map(deviceFromRow).toList(),
      positions: {
        for (final row in cachedPositions) row.deviceId: positionFromRow(row),
      },
    );

    // 2) REST 快照刷新（后台执行，不阻塞首帧）。
    unawaited(refresh());

    // 3) WebSocket 增量。
    _subscribeSocket(session, serverId);

    ref.onDispose(_teardown);
    return cached;
  }

  void _subscribeSocket(SessionState session, int serverId) {
    _teardown();
    final socket = ref.read(socketClientProvider);
    _snapshots = socket.snapshots.listen(_onSnapshot);
    _status = socket.statusStream.listen((status) {
      final current = state.valueOrNull;
      if (current != null) {
        state = AsyncData(current.copyWith(socketStatus: status));
      }
    });
    final token = session.token;
    if (token != null && token.isNotEmpty) {
      socket.reconnectWith(url: '${session.profile!.socketUrl}?token=$token');
    }
  }

  void _onSnapshot(SocketSnapshot snapshot) {
    final current = state.valueOrNull;
    if (current == null) return;
    final session = ref.read(sessionControllerProvider).value;
    final serverId = session?.profile?.id;
    if (serverId == null) return;
    final db = ref.read(appDatabaseProvider);

    // 性能 P1-a：尾迹缓冲在数据层写入（原实现误放在 mapRenderProvider 内）。
    final trailBuffer = ref.read(trailBufferProvider);
    for (final position in snapshot.positions) {
      trailBuffer.record(
        position.deviceId,
        GeoPoint(position.latitude, position.longitude),
      );
    }

    // WS 数据落库（幂等），内存态直接合并保证地图 10 秒内更新。
    if (snapshot.positions.isNotEmpty) {
      unawaited(
        db.upsertPositions(
          serverId,
          snapshot.positions.map(positionToRow(serverId)).toList(),
        ),
      );
    }
    if (snapshot.devices.isNotEmpty) {
      unawaited(
        db.upsertDevices(
          serverId,
          snapshot.devices.map(deviceToRow(serverId)).toList(),
        ),
      );
    }
    if (snapshot.events.isNotEmpty) {
      unawaited(
        db.upsertEvents(
          serverId,
          snapshot.events.map(eventToRow(serverId)).toList(),
        ),
      );
      // 事件进事件流做 UI 横幅与未读计数。
      ref.read(eventsFeedProvider.notifier).absorb(snapshot.events);
    }

    var devices = current.devices;
    if (snapshot.devices.isNotEmpty) {
      final byId = {for (final d in devices) d.id: d};
      for (final device in snapshot.devices) {
        byId[device.id] = device;
      }
      devices = byId.values.toList();
    }

    final positions = Map<int, Position>.of(current.positions);
    for (final position in snapshot.positions) {
      final existing = positions[position.deviceId];
      if (existing == null ||
          (position.fixTime ?? _epoch).isAfter(existing.fixTime ?? _epoch)) {
        positions[position.deviceId] = position;
      }
    }

    state = AsyncData(
      current.copyWith(
        devices: _sorted(devices),
        positions: positions,
      ),
    );
  }

  static final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0);

  /// REST 快照（首屏与重连后调用，docs/03 §15.2）。
  Future<void> refresh() async {
    final session = ref.read(sessionControllerProvider).value;
    final serverId = session?.profile?.id;
    if (session == null || !session.isAuthenticated || serverId == null) return;
    final db = ref.read(appDatabaseProvider);
    try {
      final api = ref.read(sessionControllerProvider.notifier).apiFor(session);
      final devices = await api.getDevices();
      final positions = await api.getPositions();

      await db.upsertDevices(
        serverId,
        devices.map(deviceToRow(serverId)).toList(),
      );
      await db.upsertPositions(
        serverId,
        positions.map(positionToRow(serverId)).toList(),
      );

      final byId = {
        for (final d in state.valueOrNull?.devices ?? const <Device>[]) d.id: d,
      };
      for (final device in devices) {
        byId[device.id] = device;
      }
      final positionsMap = Map<int, Position>.of(
        state.valueOrNull?.positions ?? const {},
      );
      for (final position in positions) {
        positionsMap[position.deviceId] = position;
      }
      state = AsyncData(
        (state.valueOrNull ?? const DevicesState()).copyWith(
          devices: _sorted(byId.values.toList()),
          positions: positionsMap,
          offline: false,
          lastRefresh: ref.read(clockProvider).now(),
        ),
      );
    } on AppFailure catch (error) {
      // 缓存可读：标记离线，不清数据（docs/02 §3.5 异常态表）。
      final current = state.valueOrNull ?? const DevicesState();
      state = AsyncData(current.copyWith(offline: true));
      AppLog.w('devices', 'refresh failed: ${error.code ?? error.message}');
    }
  }

  List<Device> _sorted(List<Device> devices) {
    // 按名称稳定排序，避免 WS 增量导致的列表闪动；本机置顶由 UI 处理。
    final list = [...devices]..sort((a, b) => a.name.compareTo(b.name));
    return List.unmodifiable(list);
  }

  void _teardown() {
    _snapshots?.cancel();
    _snapshots = null;
    _status?.cancel();
    _status = null;
  }
}

// ---- 行映射（domain ↔ drift）----

DeviceRowsCompanion Function(Device) deviceToRow(int serverId) {
  return (Device device) => DeviceRowsCompanion.insert(
        id: device.id,
        serverId: serverId,
        uniqueId: Value(device.uniqueId.isEmpty ? null : device.uniqueId),
        name: Value(device.name),
        category: Value(device.category),
        status: Value(device.status),
        lastUpdate: Value(device.lastUpdate?.millisecondsSinceEpoch),
        attributes: const Value(null),
      );
}

PositionRowsCompanion Function(Position) positionToRow(int serverId) {
  return (Position position) => PositionRowsCompanion.insert(
        id: position.id,
        serverId: serverId,
        deviceId: position.deviceId,
        fixTime: position.fixTime?.millisecondsSinceEpoch ?? 0,
        latitude: position.latitude,
        longitude: position.longitude,
        altitude: Value(position.altitude),
        speed: Value(position.speedKnots),
        course: Value(position.course),
        accuracy: Value(position.accuracy),
        battery: Value(position.batteryLevel),
        attributes: const Value(null),
      );
}

EventRowsCompanion Function(DeviceEvent) eventToRow(int serverId) {
  return (DeviceEvent event) => EventRowsCompanion.insert(
        id: event.id,
        serverId: serverId,
        deviceId: Value(event.deviceId),
        type: Value(event.type),
        eventTime: Value(event.eventTime?.millisecondsSinceEpoch),
        positionId: Value(event.positionId),
        geofenceId: Value(event.geofenceId),
      );
}

Device deviceFromRow(DeviceRow row) => Device(
      id: row.id,
      name: row.name ?? '',
      uniqueId: row.uniqueId ?? '',
      status: row.status ?? 'unknown',
      lastUpdate: row.lastUpdate == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(row.lastUpdate!),
      category: row.category,
    );

Position positionFromRow(PositionRow row) => Position(
      id: row.id,
      deviceId: row.deviceId,
      latitude: row.latitude,
      longitude: row.longitude,
      fixTime: DateTime.fromMillisecondsSinceEpoch(row.fixTime),
      speedKnots: row.speed ?? 0,
      course: row.course ?? 0,
      altitude: row.altitude,
      accuracy: row.accuracy,
      attributes: {
        if (row.battery != null) 'batteryLevel': row.battery,
      },
    );

/// 事件实时进料（WS events → UI 横幅 + 未读计数）。
class EventsFeedNotifier extends Notifier<List<DeviceEvent>> {
  @override
  List<DeviceEvent> build() => const [];

  void absorb(List<DeviceEvent> events) {
    state = [...events, ...state];
  }

  void clear() => state = const [];
}

final eventsFeedProvider =
    NotifierProvider<EventsFeedNotifier, List<DeviceEvent>>(
  EventsFeedNotifier.new,
);

final devicesControllerProvider =
    AsyncNotifierProvider<DevicesController, DevicesState>(
  DevicesController.new,
);
