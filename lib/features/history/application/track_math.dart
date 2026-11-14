import '../../../core/map/geo_point.dart';
import '../../../domain/entities/models.dart';

/// 轨迹抽稀（docs/01 §3.6：> 5000 点按距离/时间抽稀，导出用原始数据）。
abstract final class TrackThinner {
  /// 距离抽稀：相邻保留点间距 ≥ [minDistanceMeters]。
  static List<Position> byDistance(List<Position> points, double minDistanceMeters) {
    if (points.length <= 2 || minDistanceMeters <= 0) return points;
    final result = <Position>[points.first];
    var last = GeoPoint(points.first.latitude, points.first.longitude);
    for (var i = 1; i < points.length - 1; i++) {
      final point = GeoPoint(points[i].latitude, points[i].longitude);
      if (last.distanceTo(point) >= minDistanceMeters) {
        result.add(points[i]);
        last = point;
      }
    }
    result.add(points.last);
    return result;
  }

  /// Douglas–Peucker 抽稀：保留几何形状，渲染更平滑（回放用）。
  ///
  /// 性能 P2-a：用显式栈的**迭代实现**替代递归 —— 递归在病态数据
  /// （单调分布）下深度可达 O(n)，10k 点会逼近 Dart 栈上限；
  /// 迭代版栈深度恒定，复杂度平均 O(n log n)。
  static List<Position> douglasPeucker(
    List<Position> points,
    double toleranceMeters,
  ) {
    if (points.length <= 2 || toleranceMeters <= 0) return points;
    final keep = List<bool>.filled(points.length, false);
    keep[0] = keep[points.length - 1] = true;

    final stack = <List<int>>[[0, points.length - 1]];
    while (stack.isNotEmpty) {
      final segment = stack.removeLast();
      final start = segment[0];
      final end = segment[1];
      if (end <= start + 1) continue;

      final a = GeoPoint(points[start].latitude, points[start].longitude);
      final b = GeoPoint(points[end].latitude, points[end].longitude);
      var maxDistance = -1.0;
      var maxIndex = start;
      for (var i = start + 1; i < end; i++) {
        final p = GeoPoint(points[i].latitude, points[i].longitude);
        final d = _perpendicularDistance(p, a, b);
        if (d > maxDistance) {
          maxDistance = d;
          maxIndex = i;
        }
      }
      if (maxDistance > toleranceMeters) {
        keep[maxIndex] = true;
        stack.add([start, maxIndex]);
        stack.add([maxIndex, end]);
      }
    }
    return [
      for (var i = 0; i < points.length; i++)
        if (keep[i]) points[i],
    ];
  }

  /// 点到线段的球面近似距离（小尺度下用平面近似即可）。
  static double _perpendicularDistance(GeoPoint p, GeoPoint a, GeoPoint b) {
    final dx = b.longitude - a.longitude;
    final dy = b.latitude - a.latitude;
    if (dx == 0 && dy == 0) return a.distanceTo(p);
    final t = ((p.longitude - a.longitude) * dx +
            (p.latitude - a.latitude) * dy) /
        (dx * dx + dy * dy);
    final clamped = t.clamp(0.0, 1.0);
    final proj = GeoPoint(
      a.latitude + clamped * dy,
      a.longitude + clamped * dx,
    );
    return p.distanceTo(proj);
  }
}

/// 停留点（HIS-03：基于速度与半径聚类，docs/01 §3.6）。
class TrackStop {
  const TrackStop({
    required this.points,
    required this.arrival,
    required this.departure,
    required this.center,
  });

  final List<Position> points;
  final DateTime arrival;
  final DateTime departure;
  final GeoPoint center;

  Duration get duration => departure.difference(arrival);

  /// 停留中心（算术平均，展示用）。
  static TrackStop? fromCluster(List<Position> cluster) {
    if (cluster.isEmpty) return null;
    final lat = cluster.map((p) => p.latitude).reduce((a, b) => a + b) /
        cluster.length;
    final lng = cluster.map((p) => p.longitude).reduce((a, b) => a + b) /
        cluster.length;
    final first = cluster.first.fixTime;
    final last = cluster.last.fixTime;
    if (first == null || last == null) return null;
    return TrackStop(
      points: cluster,
      arrival: first,
      departure: last,
      center: GeoPoint(lat, lng),
    );
  }
}

abstract final class StopDetector {
  /// 连续 [maxSpeedMps] 以下、且离簇心不超过 [radiusMeters] 的点归为停留。
  /// 单簇不足 [minDuration] 丢弃（路过不算停留）。
  static List<TrackStop> detect(
    List<Position> points, {
    double maxSpeedMps = 0.6,
    double radiusMeters = 60,
    Duration minDuration = const Duration(minutes: 3),
  }) {
    final stops = <TrackStop>[];
    List<Position> cluster = [];
    GeoPoint? center;

    void flush() {
      final stop = TrackStop.fromCluster(cluster);
      if (stop != null && stop.duration >= minDuration) {
        stops.add(stop);
      }
      cluster = [];
      center = null;
    }

    for (final point in points) {
      final speed = point.speedMetersPerSecond;
      final geo = GeoPoint(point.latitude, point.longitude);
      final moving = speed > maxSpeedMps;
      final current = center;
      final far = current != null && current.distanceTo(geo) > radiusMeters;
      if (moving || far) {
        if (cluster.isNotEmpty) flush();
        if (moving) continue;
      }
      if (cluster.isEmpty) {
        center = geo;
      } else {
        // 簇心缓慢跟随（避免缓慢漂移被拆成多簇）。
        final previous = center ?? geo;
        center = GeoPoint(
          (previous.latitude * 9 + geo.latitude) / 10,
          (previous.longitude * 9 + geo.longitude) / 10,
        );
      }
      cluster.add(point);
    }
    if (cluster.isNotEmpty) flush();
    return stops;
  }
}

/// 行程/里程统计（HIS-05 汇总、跟踪页今日统计）。
class TrackStats {
  const TrackStats({
    required this.distanceMeters,
    required this.movingSeconds,
    required this.maxSpeedMps,
    required this.avgMovingSpeedMps,
  });

  final double distanceMeters;
  final int movingSeconds;
  final double maxSpeedMps;
  final double avgMovingSpeedMps;

  static TrackStats compute(List<Position> points) {
    var distance = 0.0;
    var movingSeconds = 0;
    var maxSpeed = 0.0;
    var movingSpeedSum = 0.0;
    var movingSamples = 0;

    for (var i = 0; i < points.length; i++) {
      final p = points[i];
      final speed = p.speedMetersPerSecond;
      if (speed > maxSpeed) maxSpeed = speed;
      if (speed > 0.6) {
        movingSpeedSum += speed;
        movingSamples++;
        final prev = i > 0 ? points[i - 1].fixTime : null;
        final cur = p.fixTime;
        if (prev != null && cur != null) {
          final delta = cur.difference(prev).inSeconds;
          movingSeconds += delta.clamp(0, 600);
        }
      }
      if (i > 0) {
        final a = GeoPoint(points[i - 1].latitude, points[i - 1].longitude);
        final b = GeoPoint(p.latitude, p.longitude);
        distance += a.distanceTo(b);
      }
    }
    return TrackStats(
      distanceMeters: distance,
      movingSeconds: movingSeconds,
      maxSpeedMps: maxSpeed,
      avgMovingSpeedMps: movingSamples == 0 ? 0 : movingSpeedSum / movingSamples,
    );
  }
}
