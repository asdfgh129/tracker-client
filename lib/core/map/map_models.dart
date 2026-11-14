import 'geo_point.dart';

/// 地图上要渲染的设备标记。业务层使用 WGS-84，渲染层负责转换。
class MapDeviceMarker {
  const MapDeviceMarker({
    required this.deviceId,
    required this.label,
    required this.point,
    this.course = 0,
    this.online = false,
    this.isSelf = false,
    this.batteryLevel,
    this.speedMetersPerSecond,
    this.clusterCount = 0,
    this.clusterDeviceIds = const [],
  });

  final int deviceId;
  final String label;
  final GeoPoint point;

  /// 方位角，0–360，0 为正北。
  final double course;
  final bool online;

  /// 是否为「本机」上报设备，UI 用不同图标与标签。
  final bool isSelf;
  final double? batteryLevel;
  final double? speedMetersPerSecond;

  /// 聚合簇（MAP-04）：> 0 表示这是一个聚合点，[label] 为设备数量，
  /// [clusterDeviceIds] 为簇内全部设备（点选后可展开/选中）。
  final int clusterCount;
  final List<int> clusterDeviceIds;

  bool get isCluster => clusterCount > 0;
}

/// 轨迹尾迹。点数由调用方按距离 / 时间抽稀后传入。
class MapTrail {
  const MapTrail({
    required this.deviceId,
    required this.points,
    this.width = 4,
  });

  final int deviceId;
  final List<GeoPoint> points;
  final int width;
}

/// 地图上的好友标记（好友体系：身份按 uniqueId，位置来自 5056 通道）。
///
/// 与设备标记分开建模：好友设备可能不在 REST 设备列表里
///（属于其他用户的设备，REST 权限不可见）。
class FriendMarker {
  const FriendMarker({
    required this.uniqueId,
    required this.label,
    required this.point,
    this.online = false,
  });

  final String uniqueId;
  final String label;
  final GeoPoint point;
  final bool online;
}

/// 地图相机目标。
class MapCameraTarget {
  const MapCameraTarget({
    required this.point,
    this.zoom = 15,
    this.animate = true,
  });

  final GeoPoint point;
  final double zoom;
  final bool animate;
}
