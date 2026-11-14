import 'package:amap_map/amap_map.dart';
import 'package:flutter/material.dart';
import 'package:x_amap_base/x_amap_base.dart';

import '../../config/build_config.dart';
import '../../observability/logger.dart';
import '../coordinate_transform.dart';
import '../geo_point.dart';
import '../map_models.dart';
import 'amap_bootstrap.dart';

/// 高德地图渲染层。
///
/// 职责边界：
/// - 输入：WGS-84（来自 Traccar），内部统一转 GCJ-02；
/// - 输出：点击回调仍返回 WGS-84，业务层无感知。
///
/// 注意：`amap_map` 的 API 以 pub.dev 文档为准；升级包版本后需回归本文件。
class AmapTrackerMap extends StatefulWidget {
  const AmapTrackerMap({
    required this.markers,
    this.friendMarkers = const [],
    this.trails = const [],
    this.initialTarget,
    this.initialZoom = 15,
    this.trafficEnabled = false,
    this.onMarkerTap,
    this.onZoomChanged,
    this.onMapReady,
    super.key,
  });

  final List<MapDeviceMarker> markers;

  /// 好友标记（好友体系）：与设备标记共用渲染管线，label 区分。
  final List<FriendMarker> friendMarkers;
  final List<MapTrail> trails;

  /// WGS-84。为空时取第一个标记，仍然为空则用天安门。
  final GeoPoint? initialTarget;
  final double initialZoom;
  final bool trafficEnabled;
  final ValueChanged<MapDeviceMarker>? onMarkerTap;

  /// 相机缩放回调（聚合开关，MAP-04：业务层带迟滞去抖）。
  final ValueChanged<double>? onZoomChanged;
  final VoidCallback? onMapReady;

  @override
  State<AmapTrackerMap> createState() => _AmapTrackerMapState();
}

class _AmapTrackerMapState extends State<AmapTrackerMap> {
  bool _sdkReady = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_sdkReady) return;
    // 能走到这里说明用户已同意地图 SDK 隐私政策（TrackerMapView 的门）。
    if (!AmapBootstrap.privacyAgreed) {
      AmapBootstrap.agreePrivacy();
    }
    AmapBootstrap.ensureInitialized(
      context,
      androidKey: BuildConfig.amapAndroidKey,
      iosKey: BuildConfig.amapIosKey,
    );
    _sdkReady = true;
  }

  @override
  Widget build(BuildContext context) {
    final target = widget.initialTarget ??
        (widget.markers.isNotEmpty
            ? widget.markers.first.point
            : (widget.friendMarkers.isNotEmpty
                ? widget.friendMarkers.first.point
                : const GeoPoint(39.9087, 116.3975)));
    final gcjTarget = _toRender(target);

    return AMapWidget(
      initialCameraPosition: CameraPosition(
        target: LatLng(gcjTarget.latitude, gcjTarget.longitude),
        zoom: widget.initialZoom,
      ),
      markers: _buildMarkers(),
      polylines: _buildPolylines(),
      trafficEnabled: widget.trafficEnabled,
      compassEnabled: true,
      scaleEnabled: true,
      onMapCreated: (controller) {
        widget.onMapReady?.call();
      },
      onCameraMove: widget.onZoomChanged == null
          ? null
          : (position) => widget.onZoomChanged!(position.zoom),
      onTap: (latLng) {
        // 用户在地图上点选：把 GCJ-02 还原成 WGS-84 后再交给业务层。
        final wgs = CoordinateTransform.gcj02ToWgs84(
          GeoPoint(latLng.latitude, latLng.longitude),
        );
        // M-4：坐标不裸 debugPrint（release 仍会输出且绕过脱敏）；
        // 走 AppLog，坐标在写入前已降到 3 位小数。
        AppLog.d('map', 'tap $wgs');
      },
    );
  }

  Set<Marker> _buildMarkers() {
    return {
      for (final marker in widget.markers)
        Marker(
          position: _toLatLng(marker.point),
          // 聚合点用橙色+数量标签，与单台设备区分（MAP-04）。
          icon: marker.isCluster
              ? BitmapDescriptor.defaultMarkerWithHue(
                  BitmapDescriptor.hueOrange,
                )
              : BitmapDescriptor.defaultMarker,
          alpha: marker.isCluster ? 0.9 : 1,
          infoWindow: InfoWindow(title: marker.label),
          onTap: (_) {
            widget.onMarkerTap?.call(marker);
          },
        ),
      // 好友标记：label 前缀区分身份（标记图标统一由地图默认样式渲染）。
      for (final friend in widget.friendMarkers)
        Marker(
          position: _toLatLng(friend.point),
          infoWindow: InfoWindow(title: '👤 ${friend.label}'),
        ),
    };
  }

  Set<Polyline> _buildPolylines() {
    return {
      for (final trail in widget.trails)
        if (trail.points.length > 1)
          Polyline(
            points: [
              for (final point in trail.points) _toLatLng(point),
            ],
            color: Theme.of(context).colorScheme.primary,
            width: trail.width.toDouble(),
          ),
    };
  }

  LatLng _toLatLng(GeoPoint point) {
    final render = _toRender(point);
    return LatLng(render.latitude, render.longitude);
  }

  /// 数据层固定 WGS-84，高德渲染层固定 GCJ-02。
  GeoPoint _toRender(GeoPoint point) => CoordinateTransform.convert(
        point,
        from: MapCoordinateSystem.wgs84,
        to: MapCoordinateSystem.gcj02,
      );
}
