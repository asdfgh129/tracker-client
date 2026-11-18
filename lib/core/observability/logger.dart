import 'dart:async';

import 'package:flutter/foundation.dart';

/// 应用内日志（docs/03 §12、docs/05 §9.3）。
///
/// 设计要点：
/// - 内存环形缓冲（默认 500 条）供诊断页展示；
/// - 脱敏优先：任何写入前先过 [redact]，禁止出现完整 Token/密码；
/// - 坐标四舍五入到 3 位小数（约 110m 精度），避免日志泄露精确行踪；
/// - 文件持久化由 [attachSink] 接管（诊断页导出用），导出走系统分享。
enum LogLevel { debug, info, warn, error }

/// 一条日志。诊断页与导出共用。
class LogEntry {
  const LogEntry({
    required this.time,
    required this.level,
    required this.module,
    required this.message,
    this.errorCode,
  });

  final DateTime time;
  final LogLevel level;
  final String module;
  final String message;
  final String? errorCode;

  String format() {
    final clock = time.toIso8601String();
    final code = errorCode == null ? '' : ' code=$errorCode';
    return '$clock ${level.name.toUpperCase().padRight(5)} $module $message$code';
  }
}

/// 日志脱敏规则（docs/01 §4.3：Token/密码仅存 Secure Storage；日志脱敏）。
abstract final class LogRedactor {
  /// JWT：三段 base64url 以点分隔（`header.payload.signature`）。
  ///
  /// 独立于长串规则：JWT 的段可能很短（测试/短 claim），
  /// 只靠长度阈值会漏掉。首段要求 ≥8 字符以降低误伤。
  static final RegExp _jwtLike = RegExp(
    r'[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+',
  );

  /// 长随机串（API Key / Session Token 等）。
  ///
  /// M-3：字符集补上 Base64 的 `+` `/` `=`，否则 `AbC+dEf/gHi=` 这类
  /// 密钥会被拆碎而漏过；阈值取 24 字符，普通单词不会被误伤。
  static final RegExp _tokenLike = RegExp(r'[A-Za-z0-9_+/=-]{24,}');

  /// 凭据键值对：`token=` / `password:` / `apikey=` / `密码=` 等。
  ///
  /// M-3：键名白名单覆盖常见变体（含 `pwd` / `apikey` / `signature` /
  /// `session`），并支持中文全角键（`密码=`）。
  /// Dart 的 RegExp **不支持内联标志** `(?i)`（会抛 FormatException），
  /// 因此用 `caseSensitive: false` 代替。
  static final RegExp _credentialPair = RegExp(
    r'(token|password|passwd|pwd|secret|apikey|api[_-]?key|authorization|auth|jwt|session|signature|sig|密码|口令|密钥)'
    r'\s*[:=]?\s*("?)[^\s"&,)]+',
    caseSensitive: false,
  );

  /// `Authorization: Basic xxx` / `Bearer xxx` —— 值可能很短或不含点，
  /// 必须在凭据键规则之后**无条件**整段吃掉（M-3）。
  static final RegExp _authScheme = RegExp(
    r'\b(basic|bearer|digest|negotiate)\s+\S+',
    caseSensitive: false,
  );

  /// 经纬度数值（保留 3 位小数，约 110m）。
  static final RegExp _coordinate = RegExp(r'-?\d{1,3}\.\d{4,}');

  /// 脱敏入口：认证方案 → 凭据 → JWT → 长 Token → 坐标精度。
  static String redact(String input) {
    var text = input;
    // 1) Basic/Bearer 等认证方案后的凭据整段脱敏。
    // 必须先于键值对规则：`Authorization: Basic xxx` 若先按键值对处理，
    // 只会吃掉方案名 `Basic`，真正的凭据（可能很短）会残留。
    text = text.replaceAllMapped(
      _authScheme,
      (match) => '${match.group(1)} <redacted>',
    );
    // 2) 键值对（保留键名便于排障）。
    text = text.replaceAllMapped(
      _credentialPair,
      (match) => '${match.group(1)}=${match.group(2)}<redacted>',
    );
    // 3) JWT（先于长串，避免被逐段处理）。
    text = text.replaceAllMapped(_jwtLike, (match) => '<redacted:jwt>');
    // 4) 剩余长随机串（含 Base64 字符集）。
    text = text.replaceAllMapped(
      _tokenLike,
      (match) => '<redacted:${match.group(0)!.length}>',
    );
    // 5) 坐标降精度（防止日志泄露精确行踪）。
    text = text.replaceAllMapped(_coordinate, (match) {
      final value = match.group(0)!;
      final parsed = double.tryParse(value);
      return parsed == null ? value : parsed.toStringAsFixed(3);
    });
    return text;
  }
}

/// 日志中心。全局单例，通过 Riverpod 注入。
///
/// 用法：`AppLog.i('socket', 'connected (attempt=1)')`。
abstract final class AppLog {
  static const int maxEntries = 500;

  static final List<LogEntry> _entries = <LogEntry>[];
  static final StreamController<LogEntry> _stream =
      StreamController<LogEntry>.broadcast();

  static void Function(LogEntry entry)? _sink;
  static LogLevel _minLevel = kDebugMode ? LogLevel.debug : LogLevel.info;

  /// 应用产生的日志流（诊断页监听）。
  static Stream<LogEntry> get stream => _stream.stream;

  /// 只读快照。
  static List<LogEntry> get entries => List.unmodifiable(_entries);

  /// 设置文件 sink（诊断/导出）。传入的函数必须自行处理落盘与轮转。
  static void attachSink(void Function(LogEntry entry) sink) => _sink = sink;

  static void setMinLevel(LogLevel level) => _minLevel = level;

  static void d(String module, String message) => _log(LogLevel.debug, module, message);

  static void i(String module, String message) => _log(LogLevel.info, module, message);

  static void w(String module, String message, {String? code}) =>
      _log(LogLevel.warn, module, message, code: code);

  static void e(String module, String message, {Object? error, String? code}) =>
      _log(
        LogLevel.error,
        module,
        error == null ? message : '$message: ${describeIdentity(error)}',
        code: code,
      );

  static void _log(LogLevel level, String module, String message,
      {String? code}) {
    if (level.index < _minLevel.index) return;
    final entry = LogEntry(
      time: DateTime.now().toUtc(),
      level: level,
      module: module,
      message: LogRedactor.redact(message),
      errorCode: code,
    );
    _entries.add(entry);
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
    _stream.add(entry);
    final sink = _sink;
    if (sink != null) {
      try {
        sink(entry);
      } catch (_) {
        // 日志失败绝不能影响业务。
      }
    }
    if (kDebugMode) {
      debugPrint(entry.format());
    }
  }

  /// 测试与登出清理用。
  static void clear() => _entries.clear();

  /// 释放测试中的流。
  static Future<void> dispose() => _stream.close();
}
