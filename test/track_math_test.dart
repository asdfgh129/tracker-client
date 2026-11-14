import 'package:flutter_test/flutter_test.dart';
import 'package:trackerone/domain/entities/models.dart';
import 'package:trackerone/features/history/application/track_export.dart';
import 'package:trackerone/features/history/application/track_math.dart';

Position _pos(
  int id,
  double lat,
  double lng,
  int minutes, {
  double knots = 0,
  double? altitude,
  double? battery,
}) {
  return Position(
    id: id,
    deviceId: 1,
    latitude: lat,
    longitude: lng,
    fixTime: DateTime.utc(2026, 11, 1, 8, minutes),
    speedKnots: knots,
    altitude: altitude,
    attributes: {
      if (battery != null) 'batteryLevel': battery,
    },
  );
}

void main() {
  group('TrackThinner', () {
    test('distance thinning keeps endpoints and sparse points', () {
      final points = [
        _pos(1, 39.9000, 116.4000, 0),
        _pos(2, 39.9001, 116.4001, 1), // ~14m
        _pos(3, 39.9010, 116.4010, 2), // ~1.4km
        _pos(4, 39.9010, 116.4010, 3), // same place
        _pos(5, 39.9020, 116.4020, 4),
      ];
      final thinned = TrackThinner.byDistance(points, 500);
      expect(thinned.first, points.first);
      expect(thinned.last, points.last);
      expect(thinned.contains(points[3]), isFalse);
    });

    test('douglas-peucker keeps shape within tolerance', () {
      final points = [
        _pos(1, 39.9000, 116.4000, 0),
        _pos(2, 39.90005, 116.40005, 1), // nearly collinear
        _pos(3, 39.9020, 116.4020, 2),
      ];
      final thinned = TrackThinner.douglasPeucker(points, 30);
      expect(thinned.length, lessThan(3));
      expect(thinned.first, points.first);
      expect(thinned.last, points.last);
    });

    test('short tracks are untouched', () {
      final points = [_pos(1, 39.9, 116.4, 0), _pos(2, 39.9, 116.4, 1)];
      expect(TrackThinner.byDistance(points, 10), same(points));
      expect(TrackThinner.douglasPeucker(points, 10), same(points));
    });
  });

  group('StopDetector (HIS-03)', () {
    test('detects a stationary cluster of >= minDuration', () {
      final points = [
        _pos(1, 39.9000, 116.4000, 0, knots: 0),
        _pos(2, 39.90001, 116.40001, 5, knots: 0),
        _pos(3, 39.90002, 116.40002, 10, knots: 0),
        _pos(4, 39.90003, 116.40003, 20, knots: 0),
        _pos(5, 39.9100, 116.4100, 30, knots: 30), // moving away
      ];
      final stops = StopDetector.detect(points);
      expect(stops, hasLength(1));
      expect(stops.first.points, hasLength(4));
      expect(stops.first.duration.inMinutes, greaterThanOrEqualTo(3));
    });

    test('ignores brief pauses', () {
      final points = [
        _pos(1, 39.9000, 116.4000, 0, knots: 0),
        _pos(2, 39.9000, 116.4000, 1, knots: 0),
        _pos(3, 39.9100, 116.4100, 2, knots: 30),
        _pos(4, 39.9200, 116.4200, 3, knots: 30),
      ];
      expect(StopDetector.detect(points), isEmpty);
    });
  });

  group('TrackStats (HIS-05)', () {
    test('computes distance and max speed', () {
      final points = [
        _pos(1, 39.9000, 116.4000, 0, knots: 10),
        _pos(2, 39.9100, 116.4100, 1, knots: 20),
      ];
      final stats = TrackStats.compute(points);
      // 0.01° 纬度约 1.11km，0.01° 经度约 0.85km → 合计约 1.4km。
      expect(stats.distanceMeters, greaterThan(1000));
      expect(stats.distanceMeters, lessThan(2000));
      // 20 knots ≈ 10.3 m/s。
      expect(stats.maxSpeedMps, closeTo(10.29, 0.1));
    });
  });

  group('TrackExporter (HIS-06)', () {
    test('gpx contains trkpt with WGS-84 coordinates and time', () {
      final gpx = TrackExporter.toGpx(
        deviceName: '京A·12345',
        points: [
          _pos(1, 39.9042, 116.4074, 0, altitude: 43, battery: 78),
        ],
      );
      expect(gpx, contains('<gpx version="1.1"'));
      expect(gpx, contains('lat="39.9042" lon="116.4074"'));
      expect(gpx, contains('<ele>43.0</ele>'));
      expect(gpx, contains('<time>2026-11-01T08:00:00.000Z</time>'));
      expect(gpx, contains('京A·12345'));
    });

    test('gpx escapes XML in device name', () {
      final gpx = TrackExporter.toGpx(
        deviceName: 'a<b>&"c',
        points: [_pos(1, 1, 2, 0)],
      );
      expect(gpx, contains('a&lt;b&gt;&amp;&quot;c'));
    });

    test('kml contains coordinates', () {
      final kml = TrackExporter.toKml(
        deviceName: 'd',
        points: [_pos(1, 39.9, 116.4, 0)],
      );
      expect(kml, contains('<LineString>'));
      expect(kml, contains('116.4,39.9,0'));
    });

    test('csv header and row', () {
      final csv = TrackExporter.toCsv([
        _pos(1, 39.9042, 116.4074, 0, knots: 5.14444, battery: 78),
      ]);
      final lines = csv.trim().split('\n');
      expect(lines, hasLength(2));
      expect(lines.first, startsWith('id,deviceId,fix_time_utc'));
      expect(lines[1], contains('39.9042,116.4074'));
      expect(lines[1], contains('78'));
    });
  });
}
