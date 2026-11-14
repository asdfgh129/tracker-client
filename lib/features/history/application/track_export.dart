import '../../../domain/entities/models.dart';

/// 轨迹导出（HIS-06：GPX / KML / CSV，永远 WGS-84，docs/04 §6 坐标约定）。
abstract final class TrackExporter {
  /// M-5：把服务端可控的设备名清洗为安全文件名片段。
  ///
  /// 只保留 `[A-Za-z0-9._-]`（中文等非 ASCII 统一替换为 `_`），
  /// 截断到 32 字符，避免目录穿越（`../`）与非法字符。
  static String safeFileName(String deviceName) {
    final cleaned = deviceName
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')
        .replaceAll(RegExp(r'_{2,}'), '_')
        .replaceAll(RegExp(r'^\.+'), '_');
    final trimmed = cleaned.length > 32 ? cleaned.substring(0, 32) : cleaned;
    return trimmed.isEmpty ? 'device' : trimmed;
  }

  static String escapeXml(String input) {
    var text = input;
    text = text.replaceAll('&', '&amp;');
    text = text.replaceAll('<', '&lt;');
    text = text.replaceAll('>', '&gt;');
    text = text.replaceAll("'", '&apos;');
    text = text.replaceAll('"', '&quot;');
    return text;
  }

  /// GPX 1.1 track。第三方工具（BaseCamp、GPX Studio）可直接打开。
  static String toGpx({
    required String deviceName,
    required List<Position> points,
  }) {
    final buffer = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln(
        '<gpx version="1.1" creator="TrackerOne" '
        'xmlns="http://www.topografix.com/GPX/1/1">',
      )
      ..writeln('  <trk>')
      ..writeln(
        '    <name>${escapeXml(deviceName)}</name>',
      )
      ..writeln('    <trkseg>');
    for (final point in points) {
      final fixTime = point.fixTime?.toUtc().toIso8601String();
      buffer
        ..writeln(
          '      <trkpt lat="${point.latitude}" lon="${point.longitude}">',
        )
        ..writeln('        <ele>${point.altitude ?? 0}</ele>');
      if (fixTime != null) {
        buffer.writeln('        <time>$fixTime</time>');
      }
      buffer
        ..writeln('        <speed>${point.speedMetersPerSecond}</speed>')
        ..writeln('      </trkpt>');
    }
    buffer
      ..writeln('    </trkseg>')
      ..writeln('  </trk>')
      ..writeln('</gpx>');
    return buffer.toString();
  }

  /// KML LineString（Google Earth 兼容）。
  static String toKml({
    required String deviceName,
    required List<Position> points,
  }) {
    final coordinates = [
      for (final point in points)
        '${point.longitude},${point.latitude},${point.altitude ?? 0}',
    ].join('\n        ');
    return '''
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <name>${escapeXml(deviceName)}</name>
    <Placemark>
      <name>${escapeXml(deviceName)} track</name>
      <LineString>
        <tessellate>1</tessellate>
        <coordinates>
        $coordinates
        </coordinates>
      </LineString>
    </Placemark>
  </Document>
</kml>
''';
  }

  /// CSV（id,deviceId,fixTime,lat,lon,altitude,speed_mps,course,accuracy,battery）。
  static String toCsv(List<Position> points) {
    final buffer = StringBuffer()
      ..writeln(
        'id,deviceId,fix_time_utc,latitude,longitude,altitude_m,speed_mps,course_deg,accuracy_m,battery_pct',
      );
    for (final point in points) {
      final fixTime = point.fixTime?.toUtc().toIso8601String() ?? '';
      buffer.writeln(
        [
          point.id,
          point.deviceId,
          fixTime,
          point.latitude,
          point.longitude,
          point.altitude ?? '',
          point.speedMetersPerSecond.toStringAsFixed(2),
          point.course,
          point.accuracy ?? '',
          point.batteryLevel ?? '',
        ].join(','),
      );
    }
    return buffer.toString();
  }

  /// 按扩展名分发。
  static String export(TrackExportFormat format, {
    required String deviceName,
    required List<Position> points,
  }) =>
      switch (format) {
        TrackExportFormat.gpx => toGpx(deviceName: deviceName, points: points),
        TrackExportFormat.kml => toKml(deviceName: deviceName, points: points),
        TrackExportFormat.csv => toCsv(points),
      };
}

enum TrackExportFormat { gpx, kml, csv }

extension TrackExportFormatX on TrackExportFormat {
  String get extension => switch (this) {
        TrackExportFormat.gpx => 'gpx',
        TrackExportFormat.kml => 'kml',
        TrackExportFormat.csv => 'csv',
      };

  String get mimeType => switch (this) {
        TrackExportFormat.gpx => 'application/gpx+xml',
        TrackExportFormat.kml => 'application/vnd.google-earth.kml+xml',
        TrackExportFormat.csv => 'text/csv',
      };
}
