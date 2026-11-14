import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'logger.dart';

/// 文件日志 sink（docs/05 §9.3：保留 7 天 / 10MB，环形覆盖，导出走系统分享）。
class FileLogSink {
  FileLogSink({
    this.maxBytes = 10 * 1024 * 1024,
    this.retention = const Duration(days: 7),
  }) {
    instance = this;
  }

  /// 当前实例（诊断页导出用）。
  static FileLogSink? instance;

  final int maxBytes;
  final Duration retention;

  File? _file;
  IOSink? _sink;
  int _bytes = 0;
  bool _failed = false;

  static const String fileName = 'trackerone.log';

  /// 附加到 AppLog（AppLog.attachSink(sink.write)）。
  Future<void> attach() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final logDir = Directory(p.join(dir.path, 'logs'));
      if (!logDir.existsSync()) logDir.createSync(recursive: true);
      await _purgeOld(logDir);
      final file = File(p.join(logDir.path, fileName));
      _bytes = file.existsSync() ? file.lengthSync() : 0;
      _file = file;
      _sink = file.openWrite(mode: FileMode.append);
      AppLog.attachSink(_write);
    } on Object {
      _failed = true;
    }
  }

  void _write(LogEntry entry) {
    if (_failed || _sink == null) return;
    try {
      final line = '${entry.format()}\n';
      _sink!.write(line);
      _bytes += line.length;
      if (_bytes >= maxBytes) {
        _rotate();
      }
    } on Object {
      _failed = true;
    }
  }

  /// 环形覆盖：达到上限时清空重写（简单、可靠，优于多文件轮转）。
  void _rotate() {
    try {
      _sink?.close();
      _file?.writeAsStringSync('');
      _bytes = 0;
      _sink = _file!.openWrite(mode: FileMode.append);
    } on Object {
      _failed = true;
    }
  }

  Future<void> _purgeOld(Directory dir) async {
    final cutoff = DateTime.now().toUtc().subtract(retention);
    await for (final entity in dir.list()) {
      if (entity is File) {
        final modified = entity.statSync().modified;
        if (modified.isBefore(cutoff)) {
          try {
            entity.deleteSync();
          } on Object {
            // 忽略单个文件清理失败。
          }
        }
      }
    }
  }

  /// 当前日志文件（诊断页导出用）。
  File? get file => _file;

  Future<void> flush() => _sink?.flush() ?? Future<void>.value();

  Future<void> close() async {
    await flush();
    await _sink?.close();
    _sink = null;
  }
}
