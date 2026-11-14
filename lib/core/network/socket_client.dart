import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../domain/entities/models.dart';
import '../observability/logger.dart';

enum SocketStatus { disconnected, connecting, connected }

/// 实时消息批次。键与 Traccar WS 协议一致（docs/04 §5.2）。
class SocketSnapshot {
  const SocketSnapshot({
    this.positions = const [],
    this.devices = const [],
    this.events = const [],
  });

  final List<Position> positions;
  final List<Device> devices;
  final List<DeviceEvent> events;

  bool get isEmpty =>
      positions.isEmpty && devices.isEmpty && events.isEmpty;
}

/// WebSocket 客户端（docs/03 §6.2）：
///
/// - 单连接，按用户/服务器隔离；
/// - 指数退避重连（1s → 30s，±20% 抖动）；恢复后请求快照（重新 connect）；
/// - 前后台切换由上层控制 [suspend]/[resume]；
/// - 解析失败记录并丢弃，不断连；
/// - 位置按 (deviceId, fixTime) 去重，事件按 id 去重。
class SocketClient {
  SocketClient({this.maxBackoff = const Duration(seconds: 30)});

  final Duration maxBackoff;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  String? _url;
  int _attempt = 0;
  bool _disposed = false;
  bool _suspended = false;

  SocketStatus _status = SocketStatus.disconnected;
  SocketStatus get status => _status;

  final _statusController = StreamController<SocketStatus>.broadcast();
  Stream<SocketStatus> get statusStream => _statusController.stream;

  final _snapshotController = StreamController<SocketSnapshot>.broadcast();
  Stream<SocketSnapshot> get snapshots => _snapshotController.stream;

  final Set<String> _seenPositionKeys = {};
  final Set<int> _seenEventIds = {};

  /// 连接。重复调用会先断开旧连接。
  void connect({required String url}) {
    if (_disposed) return;
    if (_url == url && _status != SocketStatus.disconnected) return;
    _url = url;
    _open();
  }

  void _open() {
    final url = _url;
    if (url == null || _disposed || _suspended) return;
    _closeChannel();
    _setStatus(SocketStatus.connecting);
    AppLog.d('socket', 'connecting (attempt=${_attempt + 1})');
    try {
      final channel = WebSocketChannel.connect(Uri.parse(url));
      _channel = channel;
      _subscription = channel.stream.listen(
        _onData,
        onDone: _onDone,
        onError: (Object error) => _onError(error),
        cancelOnError: true,
      );
      channel.ready.then((_) {
        if (_disposed || _channel != channel) return;
        _attempt = 0;
        _setStatus(SocketStatus.connected);
        AppLog.i('socket', 'connected');
      }).catchError((Object error) {
        _onError(error);
      });
    } on Object catch (error) {
      _onError(error);
    }
  }

  void _onData(dynamic raw) {
    try {
      final snapshot = parseMessage(raw);
      if (!snapshot.isEmpty) {
        _snapshotController.add(snapshot);
      }
    } on Object catch (error) {
      // 解析失败不崩溃、不断连（docs/04 §5.3）。
      AppLog.w('socket', 'message parse failed: $error');
    }
  }

  /// 解析 WS 消息为快照（公开以便单元测试）。
  ///
  /// 容错：非字符串、空串、非法 JSON、非对象结构一律返回空快照，
  /// 不断连、不抛出（docs/04 §5.3）。
  SocketSnapshot parseMessage(dynamic raw) {
    if (raw is! String || raw.isEmpty) return const SocketSnapshot();
    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const SocketSnapshot();
    }
    if (decoded is! Map<String, dynamic>) return const SocketSnapshot();
    final map = decoded;

    final positions = <Position>[];
    final devices = <Device>[];
    final events = <DeviceEvent>[];

    for (final entry in map.entries) {
      final value = entry.value;
      if (value is! List) continue;
      switch (entry.key) {
        case 'positions':
          for (final item in value) {
            if (item is! Map<String, dynamic>) continue;
            final position = Position.fromJson(item);
            final key = positionKey(position);
            if (!_seenPositionKeys.add(key)) continue;
            positions.add(position);
          }
        case 'devices':
          for (final item in value) {
            if (item is! Map<String, dynamic>) continue;
            devices.add(Device.fromJson(item));
          }
        case 'events':
          for (final item in value) {
            if (item is! Map<String, dynamic>) continue;
            final event = DeviceEvent.fromJson(item);
            if (!_seenEventIds.add(event.id)) continue;
            events.add(event);
          }
        default:
          break; // 未知键忽略（logs 等）。
      }
    }

    // 去重集合防膨胀：位置只保留最近状态，事件超过 1000 清一半。
    if (_seenEventIds.length > 1000) {
      _seenEventIds.clear();
    }
    if (_seenPositionKeys.length > 5000) {
      _seenPositionKeys.clear();
    }

    return SocketSnapshot(
      positions: positions,
      devices: devices,
      events: events,
    );
  }

  /// 位置幂等键：(deviceId, fixTime)（docs/03 §6.2）。
  static String positionKey(Position position) {
    final fixTime = position.fixTime;
    return '${position.deviceId}:${fixTime?.millisecondsSinceEpoch ?? 0}';
  }

  void _onDone() => _scheduleReconnect('closed');

  void _onError(Object error) {
    AppLog.w('socket', 'error: ${describeIdentity(error)}');
    _scheduleReconnect('error');
  }

  void _scheduleReconnect(String reason) {
    if (_disposed || _suspended) return;
    _closeChannel();
    _setStatus(SocketStatus.disconnected);
    final baseMs = math.min(
      1000 * (1 << _attempt.clamp(0, 5)),
      maxBackoff.inMilliseconds,
    );
    final jitter = baseMs * 0.2 * (math.Random().nextDouble() * 2 - 1);
    final delay = Duration(milliseconds: (baseMs + jitter).round());
    _attempt += 1;
    AppLog.d('socket', 'reconnect in ${delay.inMilliseconds}ms ($reason)');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, _open);
  }

  /// 立即重连（前台恢复 / 网络恢复时调用，docs/03 §6.3）。
  void resume() {
    if (_disposed) return;
    _suspended = false;
    if (_status == SocketStatus.connected) return;
    _attempt = 0;
    _reconnectTimer?.cancel();
    _open();
  }

  /// 进入后台：主动断开省电（docs/03 §6.2 后台 30s 断开）。
  void suspend() {
    _suspended = true;
    _reconnectTimer?.cancel();
    _closeChannel();
    _setStatus(SocketStatus.disconnected);
  }

  /// 登出 / 换服务器时彻底断开且不自动重连，直到下次 [connect]。
  void disconnect() {
    _reconnectTimer?.cancel();
    _url = null;
    _attempt = 0;
    _seenPositionKeys.clear();
    _seenEventIds.clear();
    _closeChannel();
    _setStatus(SocketStatus.disconnected);
  }

  /// 更换服务器/用户时调用：清空去重状态并重连。
  void reconnectWith({required String url}) {
    _seenPositionKeys.clear();
    _seenEventIds.clear();
    _attempt = 0;
    _url = url;
    _reconnectTimer?.cancel();
    _open();
  }

  void _closeChannel() {
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close(ws_status.normalClosure);
    _channel = null;
  }

  void _setStatus(SocketStatus value) {
    if (_status == value) return;
    _status = value;
    _statusController.add(value);
  }

  Future<void> dispose() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    await _subscription?.cancel();
    await _channel?.sink.close(ws_status.normalClosure);
    await _statusController.close();
    await _snapshotController.close();
  }
}
