import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../observability/log_sink.dart';
import '../observability/logger.dart';

/// H-6：本地敏感数据的删除实现（行踪轨迹属敏感个人信息，删除权必须落实）。
///
/// 覆盖：日志目录、历史导出的临时 GPX/KML/CSV。
/// 调用方（settings / session）负责数据库与 Secure Storage 部分。
abstract final class DataEraser {
  /// 删除日志目录下的全部日志文件。
  static Future<bool> eraseLogs() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final logDir = Directory(p.join(dir.path, 'logs'));
      if (logDir.existsSync()) {
        await logDir.delete(recursive: true);
      }
      // 让 sink 的句柄与内存缓冲同时失效，避免继续写已删除的路径。
      await FileLogSink.instance?.close();
      AppLog.clear();
      return true;
    } on Object catch (error) {
      AppLog.w('privacy', 'erase logs failed', code: '$error');
      return false;
    }
  }

  /// 删除历史导出留下的临时文件（全精度 WGS-84 轨迹）。
  static Future<bool> eraseExports() async {
    try {
      for (final dir in await _exportDirs()) {
        if (!dir.existsSync()) continue;
        await for (final entity in dir.list()) {
          if (entity is! File) continue;
          final name = p.basename(entity.path);
          if (name.startsWith('trackerone_') &&
              _hasExportExtension(name)) {
            try {
              await entity.delete();
            } on Object {
              // 单个文件删除失败不阻断其余清理。
            }
          }
        }
      }
      return true;
    } on Object catch (error) {
      AppLog.w('privacy', 'erase exports failed', code: '$error');
      return false;
    }
  }

  static bool _hasExportExtension(String name) =>
      name.endsWith('.gpx') || name.endsWith('.kml') || name.endsWith('.csv');

  /// 临时目录 + 文档目录（导出历史实现可能落在两者之一）。
  static Future<List<Directory>> _exportDirs() async {
    final dirs = <Directory>[];
    try {
      dirs.add(await getTemporaryDirectory());
    } on Object {
      // 无临时目录（部分桌面环境）时忽略。
    }
    try {
      dirs.add(await getApplicationDocumentsDirectory());
    } on Object {
      // 忽略。
    }
    return dirs;
  }
}
