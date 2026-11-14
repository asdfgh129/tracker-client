import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/map/geo_point.dart';
import '../../../core/map/map_models.dart';
import '../../../core/storage/database.dart';
import '../../../core/storage/preferences.dart';
import '../../../domain/entities/models.dart';
import '../../devices/application/devices_controller.dart';
import '../../friends/application/friends_controller.dart';
import '../../settings/application/settings_controller.dart';

/// 交互状态（搜索/筛选/选中/跟随）。
class MapQueryState {
  const MapQueryState({
    this.searchQuery = '',
    this.showOfflineOnly = false,
    this.selectedDeviceId,
    this.followDeviceId,
  });

  final String searchQuery;
  final bool showOfflineOnly;
  final int? selectedDeviceId;

  /// 跟随模式（MAP-05）：地图持续居中该设备，用户拖动即退出。
  final int? followDeviceId;

  MapQueryState copyWith({
    String? searchQuery,
    bool? showOfflineOnly,
    int? selectedDeviceId,
    bool clearSelected = false,
    int? followDeviceId,
    bool clearFollow = false,
  }) {
    return MapQueryState(
      searchQuery: searchQuery ?? this.searchQuery,
      showOfflineOnly: showOfflineOnly ?? this.showOfflineOnly,
      selectedDeviceId:
          clearSelected ? null : (selectedDeviceId ?? this.selectedDeviceId),
      followDeviceId:
          clearFollow ? null : (followDeviceId ?? this.followDeviceId),
    );
  }
}

class MapQueryNotifier extends Notifier<MapQueryState> {
  @override
  MapQueryState build() => const MapQueryState();

  void select(int? deviceId) => state = deviceId == null
      ? state.copyWith(clearSelected: true)
      : state.copyWith(selectedDeviceId: deviceId);

  void setFollow(int? deviceId) => state = deviceId == null
      ? state.copyWith(clearFollow: true)
      : state.copyWith(followDeviceId: deviceId, selectedDeviceId: deviceId);

  void setSearch(String query) => state = state.copyWith(searchQuery: query);

  void toggleOfflineOnly() =>
      state = state.copyWith(showOfflineOnly: !state.showOfflineOnly);

  /// 用户手动拖动地图 → 退出跟随（docs/02 §3.5）。
  void onUserPan() {
    if (state.followDeviceId != null) {
      state = state.copyWith(clearFollow: true);
    }
  }
}

final mapQueryProvider =
    NotifierProvider<MapQueryNotifier, MapQueryState>(MapQueryNotifier.new);

/// 每设备尾迹缓冲（MAP-06：最近 50 点）。进程内即可，不持久化。
///
/// 写入只发生在数据层（DevicesController 收到位置更新时），
/// 渲染派生层只读 —— 保证 provider 无副作用。
class TrailBuffer {
  final Map<int, List<GeoPoint>> _trails = {};

  static const int maxLength = 50;

  /// 数据层写入：记录一个新位置（内部做长度裁剪，O(1) 摊销）。
  void record(int deviceId, GeoPoint point) {
    final existing = _trails[deviceId];
    if (existing == null) {
      _trails[deviceId] = [point];
      return;
    }
    if (existing.length >= maxLength) {
      // 滚动裁剪：sublist 一次 O(maxLength)。
      _trails[deviceId] = [...existing.sublist(1), point];
    } else {
      existing.add(point);
      _trails[deviceId] = List.of(existing);
    }
  }

  /// 渲染层只读。
  List<GeoPoint>? trailOf(int deviceId) => _trails[deviceId];

  void clear() => _trails.clear();
}

final trailBufferProvider = Provider<TrailBuffer>((ref) => TrailBuffer());

/// 地图渲染数据（标记/尾迹/好友标记），由设备数据 + 查询状态派生。
///
/// 聚合（MAP-04）改在 UI 层做（clusterMarkers，缩放感知）：
/// 聚合结果依赖相机 zoom，而 zoom 属于屏幕状态，不适合进纯派生 provider。
class MapRenderState {
  const MapRenderState({
    this.markers = const [],
    this.friendMarkers = const [],
    this.trails = const [],
    this.initialTarget,
  });

  final List<MapDeviceMarker> markers;
  final List<FriendMarker> friendMarkers;
  final List<MapTrail> trails;
  final GeoPoint? initialTarget;

  /// 跟随目标的当前位置（相机居中用）。
  GeoPoint? targetOf(int? deviceId, Map<int, Position> positions) {
    if (deviceId == null) return null;
    final position = positions[deviceId];
    if (position == null) return null;
    return GeoPoint(position.latitude, position.longitude);
  }
}

// 性能 P1-a：provider 必须是纯派生。尾迹缓冲的**写入**已移到
// DevicesController._onSnapshot（数据层），此处只读，避免
// 「build 时写 provider」导致的连锁重算与不可预测的重建顺序。
final mapRenderProvider = Provider<MapRenderState>((ref) {
  final devicesState = ref.watch(devicesControllerProvider).valueOrNull;
  final query = ref.watch(mapQueryProvider);
  final settings = ref.watch(settingsProvider);
  final buffer = ref.watch(trailBufferProvider);
  final friends = ref.watch(friendsListProvider).valueOrNull ?? const <FriendRow>[];

  if (devicesState == null) return const MapRenderState();

  final selfDeviceId =
      ref.watch(prefsProvider).getInt(PrefKeys.trackingDeviceId);
  final lowerQuery = query.searchQuery.toLowerCase();

  final markers = <MapDeviceMarker>[];
  final friendMarkers = <FriendMarker>[];
  final trails = <MapTrail>[];

  for (final device in devicesState.devices) {
    final position = devicesState.positions[device.id];
    if (position == null) continue;
    if (lowerQuery.isNotEmpty &&
        !device.name.toLowerCase().contains(lowerQuery) &&
        !device.uniqueId.contains(lowerQuery)) {
      continue;
    }
    if (query.showOfflineOnly && device.isOnline) continue;

    final point = GeoPoint(position.latitude, position.longitude);
    markers.add(
      MapDeviceMarker(
        deviceId: device.id,
        label: device.name,
        point: point,
        course: position.course,
        online: device.isOnline,
        isSelf: device.id == selfDeviceId,
        batteryLevel: position.batteryLevel,
        speedMetersPerSecond: position.speedMetersPerSecond,
      ),
    );
    if (settings.mapTrail) {
      final trail = buffer.trailOf(device.id);
      if (trail != null && trail.length > 1) {
        trails.add(MapTrail(deviceId: device.id, points: trail));
      }
    }
  }

  // 好友图层（好友体系）：仅 accepted 且有位置的好友上地图。
  for (final friend in friends) {
    if (friend.status != 'accepted') continue;
    if (friend.lastLatitude == null || friend.lastLongitude == null) continue;
    if (lowerQuery.isNotEmpty &&
        !(friend.name ?? '').toLowerCase().contains(lowerQuery) &&
        !friend.uniqueId.contains(lowerQuery)) {
      continue;
    }
    friendMarkers.add(FriendMarker(
      uniqueId: friend.uniqueId,
      label: (friend.name?.isNotEmpty ?? false) ? friend.name! : friend.uniqueId,
      point: GeoPoint(friend.lastLatitude!, friend.lastLongitude!),
      online: friend.online,
    ));
  }

  // 初始相机：跟随目标 > 本机 > 第一个设备 > 第一个好友。
  GeoPoint? initialTarget;
  final followTarget = query.followDeviceId == null
      ? null
      : devicesState.positions[query.followDeviceId];
  if (followTarget != null) {
    initialTarget = GeoPoint(followTarget.latitude, followTarget.longitude);
  } else if (selfDeviceId != null &&
      devicesState.positions.containsKey(selfDeviceId)) {
    final self = devicesState.positions[selfDeviceId]!;
    initialTarget = GeoPoint(self.latitude, self.longitude);
  } else if (markers.isNotEmpty) {
    initialTarget = markers.first.point;
  } else if (friendMarkers.isNotEmpty) {
    initialTarget = friendMarkers.first.point;
  }

  return MapRenderState(
    markers: markers,
    friendMarkers: friendMarkers,
    trails: trails,
    initialTarget: initialTarget,
  );
});
