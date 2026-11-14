import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../observability/logger.dart';
import '../../domain/failures.dart';

/// 消息通道状态。
enum MessagingStatus {
  disconnected,
  connecting,
  authenticating,

  /// 认证通过，好友/定位请求可用。
  connected,

  /// 认证被拒（密码不符等）：自动重连无法解决，需上层干预。
  failed,
}

int? asIntOrNull(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

double? asDoubleOrNull(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '');
}

DateTime? asTimeOrNull(Object? value) {
  if (value == null) return null;
  if (value is num) {
    final ms = value < 100000000000 ? (value * 1000).round() : value.round();
    return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }
  return DateTime.tryParse(value.toString());
}

/// friends.list 列表项（含最后位置快照）。
class FriendEntry {
  const FriendEntry({
    required this.uniqueId,
    this.deviceId,
    this.name,
    required this.status,
    required this.online,
    this.latitude,
    this.longitude,
    this.lastTime,
  });

  final String uniqueId;

  /// 服务端设备 id（friends.list / 广播 from 节点都会带）。
  final int? deviceId;
  final String? name;

  /// `accepted` / `pending_in` / `pending_out`（与 drift FriendRows.status 一致）。
  final String status;
  final bool online;
  final double? latitude;
  final double? longitude;
  final DateTime? lastTime;

  static FriendEntry? fromJson(Map<String, dynamic> json) {
    final uniqueId = json['uniqueId']?.toString();
    if (uniqueId == null || uniqueId.isEmpty) return null;
    final position = json['position'];
    return FriendEntry(
      uniqueId: uniqueId,
      deviceId: asIntOrNull(json['id']),
      name: json['name']?.toString(),
      status: json['status']?.toString() ?? 'pending_out',
      online: json['online'] == true,
      latitude:
          position is Map<String, dynamic> ? asDoubleOrNull(position['latitude']) : null,
      longitude:
          position is Map<String, dynamic> ? asDoubleOrNull(position['longitude']) : null,
      lastTime: asTimeOrNull(json['lastTime']),
    );
  }

}

/// 收到好友申请（friends.invite）。
class FriendInvite {
  const FriendInvite({
    required this.fromUniqueId,
    this.fromDeviceId,
    this.fromName,
  });

  final String fromUniqueId;
  final int? fromDeviceId;
  final String? fromName;
}

/// 好友关系变化（friends.response：accepted/rejected/removed）。
class FriendResponse {
  const FriendResponse({
    required this.fromUniqueId,
    this.fromDeviceId,
    this.fromName,
    required this.action,
  });

  final String fromUniqueId;
  final int? fromDeviceId;
  final String? fromName;
  final String action;
}

/// 收到实时定位请求（location.request 推送）。
class IncomingLocationRequest {
  const IncomingLocationRequest({
    required this.requestId,
    required this.fromUniqueId,
    this.fromDeviceId,
    this.fromName,
  });

  final int requestId;
  final String fromUniqueId;
  final int? fromDeviceId;
  final String? fromName;
}

/// 定位请求结果（location.push：timeout/declined，或携带位置）。
class LocationPushResult {
  const LocationPushResult({
    required this.requestId,
    required this.status,
    this.fromUniqueId,
    this.fromDeviceId,
    this.fromName,
    this.latitude,
    this.longitude,
    this.time,
  });

  final int requestId;

  /// `timeout` / `declined`，成功时为 null（见 [latitude]）。
  final String? status;
  final String? fromUniqueId;
  final int? fromDeviceId;
  final String? fromName;
  final double? latitude;
  final double? longitude;
  final DateTime? time;
}

/// 好友位置实时广播（location.push status="update"）。
class FriendPositionUpdate {
  const FriendPositionUpdate({
    required this.fromUniqueId,
    this.fromDeviceId,
    this.fromName,
    required this.latitude,
    required this.longitude,
    this.time,
    this.speed,
    this.batteryLevel,
  });

  final String fromUniqueId;
  final int? fromDeviceId;
  final String? fromName;
  final double latitude;
  final double longitude;
  final DateTime? time;
  final double? speed;
  final double? batteryLevel;
}

/// 请求方视角的定位请求回执。
class LocationRequestAck {
  const LocationRequestAck({
    required this.requestId,
    required this.status,
    this.latitude,
    this.longitude,
    this.lastTime,
  });

  final int requestId;

  /// `sent`（对方在线已转发）或 `offline`（附最后已知位置）。
  final String status;
  final double? latitude;
  final double? longitude;
  final DateTime? lastTime;
}

/// 5056 消息通道客户端（好友体系，协议见 tracker-server docs/design-cn.md §5）。
///
/// - 单连接；连接后须在服务端 authTimeout（默认 30s）内完成设备认证；
/// - 指数退避重连（复用 SocketClient 的节奏 1s → 30s ±20%）；认证失败
///   （password_mismatch 等）不再自动重试，置为 [MessagingStatus.failed]；
/// - 请求-应答按 type 关联；推送类消息走独立流，供 UI/控制器消费。
class MessagingClient {
  MessagingClient({this.maxBackoff = const Duration(seconds: 30)});

  final Duration maxBackoff;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  Timer? _authTimer;
  String? _url;
  String? _uniqueId;
  String? _password;
  int _attempt = 0;
  bool _disposed = false;
  bool _suspended = false;
  bool _authPending = false;

  MessagingStatus _status = MessagingStatus.disconnected;
  MessagingStatus get status => _status;

  final _statusController = StreamController<MessagingStatus>.broadcast();
  Stream<MessagingStatus> get statusStream => _statusController.stream;

  final _friendsController = StreamController<List<FriendEntry>>.broadcast();
  Stream<List<FriendEntry>> get friendsStream => _friendsController.stream;

  final _invitesController = StreamController<FriendInvite>.broadcast();
  Stream<FriendInvite> get invitesStream => _invitesController.stream;

  final _responsesController = StreamController<FriendResponse>.broadcast();
  Stream<FriendResponse> get responsesStream => _responsesController.stream;

  final _requestsController = StreamController<IncomingLocationRequest>.broadcast();
  Stream<IncomingLocationRequest> get requestsStream => _requestsController.stream;

  final _updatesController = StreamController<FriendPositionUpdate>.broadcast();
  Stream<FriendPositionUpdate> get updatesStream => _updatesController.stream;

  final _pushesController = StreamController<LocationPushResult>.broadcast();
  Stream<LocationPushResult> get pushesStream => _pushesController.stream;

  /// 同 type 应答的排队等待者（支持并发同类请求）。
  final Map<String, List<Completer<Map<String, dynamic>>>> _ackWaiters = {};
  Completer<List<FriendEntry>>? _friendsWaiter;

  /// 连接并认证。重复调用先断开旧连接。
  void connect({
    required String url,
    required String uniqueId,
    String? password,
  }) {
    if (_disposed) return;
    _url = url;
    _uniqueId = uniqueId;
    _password = password;
    _attempt = 0;
    _open();
  }

  void _open() {
    final url = _url;
    final uniqueId = _uniqueId;
    if (url == null || uniqueId == null || _disposed || _suspended) return;
    _closeChannel();
    _setStatus(MessagingStatus.connecting);
    AppLog.d('messaging', 'connecting (attempt=${_attempt + 1})');
    try {
      final channel = WebSocketChannel.connect(Uri.parse(url));
      _channel = channel;
      _subscription = channel.stream.listen(
        _onData,
        onDone: _onDone,
        onError: (Object error) => _scheduleReconnect('error'),
        cancelOnError: true,
      );
      channel.ready.then((_) {
        if (_disposed || _channel != channel) return;
        _setStatus(MessagingStatus.authenticating);
        _sendAuth();
      }).catchError((Object error) {
        _scheduleReconnect('connect failed');
      });
    } on Object {
      _scheduleReconnect('connect error');
    }
  }

  void _sendAuth() {
    final uniqueId = _uniqueId;
    if (uniqueId == null) return;
    _authPending = true;
    final json = <String, dynamic>{
      'type': 'auth',
      'uniqueId': uniqueId,
      if (_password != null && _password!.isNotEmpty) 'password': _password,
    };
    _channel?.sink.add(jsonEncode(json));
    // 服务端 authTimeout（默认 30s）会断开；客户端更早发现以便快速重试。
    _authTimer?.cancel();
    _authTimer = Timer(const Duration(seconds: 10), () {
      if (_authPending && !_disposed) {
        AppLog.w('messaging', 'auth timed out');
        _scheduleReconnect('auth timeout');
      }
    });
  }

  // ---- 业务 API（认证后可用）----

  /// 拉取好友列表快照。
  ///
  /// 超时抛 [MessagingFailure]（请求已发出、结果未知），不再悬挂等待。
  Future<List<FriendEntry>> listFriends() async {
    final waiter = Completer<List<FriendEntry>>();
    _friendsWaiter = waiter;
    _channel?.sink.add(jsonEncode({'type': 'friends.list'}));
    try {
      return await waiter.future.timeout(const Duration(seconds: 12));
    } on TimeoutException {
      if (_friendsWaiter == waiter) _friendsWaiter = null;
      throw const MessagingFailure();
    }
  }

  /// 发送好友申请。返回服务器给出的状态（pending / accepted）。
  Future<String> requestFriend(String uniqueId) async {
    final ack = await _call('friends.request', {'uniqueId': uniqueId});
    return ack['status']?.toString() ?? 'pending';
  }

  Future<void> acceptFriend(String uniqueId) =>
      _call('friends.accept', {'uniqueId': uniqueId});

  Future<void> rejectFriend(String uniqueId) =>
      _call('friends.reject', {'uniqueId': uniqueId});

  Future<void> removeFriend(String uniqueId) =>
      _call('friends.remove', {'uniqueId': uniqueId});

  /// 设置/修改/清除设备密码（password 为 null 表示清除）。
  Future<void> setPassword({String? password, String? oldPassword}) => _call(
        'register',
        {
          if (password != null) 'password': password,
          if (oldPassword != null) 'oldPassword': oldPassword,
        },
      );

  /// 请求对方实时位置。返回 ack（sent / offline+最后位置）。
  Future<LocationRequestAck> requestLocation(
    String uniqueId, {
    int timeoutSeconds = 30,
  }) async {
    final ack = await _call(
      'location.request',
      {'uniqueId': uniqueId, 'timeout': timeoutSeconds},
    );
    final position = ack['position'];
    return LocationRequestAck(
      requestId: asIntOrNull(ack['requestId']) ?? 0,
      status: ack['status']?.toString() ?? 'sent',
      latitude: position is Map ? asDoubleOrNull(position['latitude']) : null,
      longitude: position is Map ? asDoubleOrNull(position['longitude']) : null,
      lastTime: asTimeOrNull(ack['lastTime']),
    );
  }

  /// 回应定位请求（携带当前位置）。
  Future<void> replyLocation(
    int requestId, {
    required double latitude,
    required double longitude,
    double? accuracy,
    double? speed,
    double? batteryLevel,
    bool charging = false,
  }) =>
      _call('location.reply', {
        'requestId': requestId,
        'position': {
          'latitude': latitude,
          'longitude': longitude,
          if (accuracy != null) 'accuracy': accuracy,
          if (speed != null) 'speed': speed,
          if (batteryLevel != null) 'batteryLevel': batteryLevel.round(),
          'charging': charging,
          'time': DateTime.now().toUtc().toIso8601String(),
        },
      });

  /// 拒绝定位请求。
  Future<void> declineLocation(int requestId) =>
      _call('location.reply', {'requestId': requestId, 'declined': true});

  Future<Map<String, dynamic>> _call(
    String type,
    Map<String, dynamic> body,
  ) async {
    final waiter = Completer<Map<String, dynamic>>();
    _ackWaiters.putIfAbsent(type, () => []).add(waiter);
    _channel?.sink.add(jsonEncode({...body, 'type': type}));
    try {
      return await waiter.future.timeout(const Duration(seconds: 12));
    } on TimeoutException {
      // 从等待队列移除，避免泄漏与迟到应答写入已死的 completer。
      _ackWaiters[type]?.remove(waiter);
      // 超时 = 请求已发出、结果未知：抛出统一通道错误，调用方
      // 不得把伪造应答当服务端决定（修复静默假应答缺陷）。
      throw const MessagingFailure();
    }
  }

  // ---- 消息解析 ----

  void _onData(dynamic raw) {
    if (raw is! String || raw.isEmpty) return;
    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      AppLog.w('messaging', 'invalid json dropped');
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    _handleMessage(decoded);
  }

  /// 解析一条服务器消息并分发（公开以便单元测试）。
  void handleMessageForTest(Map<String, dynamic> json) => _handleMessage(json);

  void _handleMessage(Map<String, dynamic> json) {
    final type = json['type']?.toString();

    // 服务器主动断开前的错误帧（未认证/密码不符/替换连接）。
    if (type == 'error') {
      final reason = json['reason']?.toString() ?? '';
      AppLog.w('messaging', 'server error: $reason');
      if (reason == 'password_mismatch' || reason == 'unknown_device') {
        // 自动重连无法解决，交上层处理。
        _setStatus(MessagingStatus.failed);
        _closeChannel();
        return;
      }
      if (reason == 'connection_replaced') {
        // 本机新连接替换旧连接：等新连接接管，旧的静默退出。
        return;
      }
      if (_authPending || reason == 'not_authenticated') {
        _scheduleReconnect('auth rejected: $reason');
        return;
      }
      return;
    }

    // 认证应答。
    if (type == 'auth') {
      _authTimer?.cancel();
      _authPending = false;
      if (json['success'] == true) {
        _attempt = 0;
        _setStatus(MessagingStatus.connected);
        AppLog.i('messaging', 'authenticated');
        unawaited(_refreshAfterAuth());
      } else {
        _setStatus(MessagingStatus.failed);
        _closeChannel();
      }
      return;
    }

    // 请求-应答类。
    if (json.containsKey('success')) {
      switch (type) {
        case 'friends.list':
          final waiter = _friendsWaiter;
          _friendsWaiter = null;
          final friends = <FriendEntry>[];
          final items = json['friends'];
          if (items is List) {
            for (final item in items) {
              if (item is Map<String, dynamic>) {
                final entry = FriendEntry.fromJson(item);
                if (entry != null) friends.add(entry);
              }
            }
          }
          if (json['success'] == true) {
            _friendsController.add(friends);
            waiter?.complete(friends);
          } else {
            waiter?.completeError(
              StateError(json['reason']?.toString() ?? 'unknown'),
            );
          }
          return;
        case 'location.request':
          _completeAck(type, json);
          return;
        case 'location.reply':
        case 'friends.request':
        case 'friends.accept':
        case 'friends.reject':
        case 'friends.remove':
        case 'register':
        case 'location.update':
          _completeAck(type, json);
          return;
      }
    }

    // 推送类。
    switch (type) {
      case 'friends.invite':
        final from = json['from'];
        if (from is Map<String, dynamic>) {
          final uniqueId = from['uniqueId']?.toString();
          if (uniqueId != null) {
            _invitesController.add(FriendInvite(
              fromUniqueId: uniqueId,
              fromDeviceId: asIntOrNull(from['id']),
              fromName: from['name']?.toString(),
            ));
          }
        }
      case 'friends.response':
        final from = json['from'];
        if (from is Map<String, dynamic>) {
          final uniqueId = from['uniqueId']?.toString();
          if (uniqueId != null) {
            _responsesController.add(FriendResponse(
              fromUniqueId: uniqueId,
              fromDeviceId: asIntOrNull(from['id']),
              fromName: from['name']?.toString(),
              action: json['action']?.toString() ?? '',
            ));
          }
        }
      case 'location.request':
        final from = json['from'];
        final requestId = asIntOrNull(json['requestId']);
        final fromId = from is Map<String, dynamic>
            ? from['uniqueId']?.toString()
            : null;
        if (requestId != null && fromId != null) {
          _requestsController.add(IncomingLocationRequest(
            requestId: requestId,
            fromUniqueId: fromId,
            fromDeviceId: from is Map<String, dynamic> ? asIntOrNull(from['id']) : null,
            fromName: from is Map<String, dynamic> ? from['name']?.toString() : null,
          ));
        }
      case 'location.push':
        if (json['status']?.toString() == 'update') {
          _emitBroadcast(json);
        } else {
          _emitPushResult(json);
        }
      default:
        break; // 未知 type 忽略。
    }
  }

  Future<void> _refreshAfterAuth() async {
    try {
      await listFriends();
    } on Object catch (error) {
      AppLog.w('messaging', 'friends.list after auth failed: $error');
    }
  }

  void _completeAck(String? type, Map<String, dynamic> json) {
    final waiters = _ackWaiters[type];
    if (waiters == null || waiters.isEmpty) return;
    final waiter = waiters.removeAt(0);
    if (waiters.isEmpty) _ackWaiters.remove(type);
    if (json['success'] == true) {
      waiter.complete(json);
    } else {
      waiter.completeError(
        StateError(json['reason']?.toString() ?? 'unknown'),
      );
    }
  }

  void _emitBroadcast(Map<String, dynamic> json) {
    final from = json['from'];
    final position = json['position'];
    final fromId = from is Map<String, dynamic> ? from['uniqueId']?.toString() : null;
    if (fromId == null || position is! Map<String, dynamic>) return;
    final latitude = asDoubleOrNull(position['latitude']);
    final longitude = asDoubleOrNull(position['longitude']);
    if (latitude == null || longitude == null) return;
    _updatesController.add(FriendPositionUpdate(
      fromUniqueId: fromId,
      fromDeviceId: from is Map<String, dynamic> ? asIntOrNull(from['id']) : null,
      fromName: from is Map<String, dynamic> ? from['name']?.toString() : null,
      latitude: latitude,
      longitude: longitude,
      time: asTimeOrNull(position['time']),
      speed: asDoubleOrNull(position['speed']),
      batteryLevel: asDoubleOrNull(position['batteryLevel']),
    ));
  }

  void _emitPushResult(Map<String, dynamic> json) {
    final requestId = asIntOrNull(json['requestId']);
    if (requestId == null) return;
    final from = json['from'];
    final position = json['position'];
    _pushesController.add(LocationPushResult(
      requestId: requestId,
      status: json['status']?.toString(),
      fromUniqueId: from is Map<String, dynamic> ? from['uniqueId']?.toString() : null,
      fromDeviceId: from is Map<String, dynamic> ? asIntOrNull(from['id']) : null,
      fromName: from is Map<String, dynamic> ? from['name']?.toString() : null,
      latitude: position is Map ? asDoubleOrNull(position['latitude']) : null,
      longitude: position is Map ? asDoubleOrNull(position['longitude']) : null,
      time: position is Map ? asTimeOrNull(position['time']) : null,
    ));
  }

  // ---- 连接生命周期（节奏与 SocketClient 一致）----

  void _onDone() => _scheduleReconnect('closed');

  void _scheduleReconnect(String reason) {
    if (_disposed || _suspended) return;
    _closeChannel();
    if (_status == MessagingStatus.failed) return;
    _setStatus(MessagingStatus.disconnected);
    final baseMs = math.min(
      1000 * (1 << _attempt.clamp(0, 5)),
      maxBackoff.inMilliseconds,
    );
    final jitter = baseMs * 0.2 * (math.Random().nextDouble() * 2 - 1);
    final delay = Duration(milliseconds: (baseMs + jitter).round());
    _attempt += 1;
    AppLog.d('messaging', 'reconnect in ${delay.inMilliseconds}ms ($reason)');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, _open);
  }

  void resume() {
    if (_disposed) return;
    _suspended = false;
    if (_status == MessagingStatus.connected ||
        _status == MessagingStatus.authenticating) {
      return;
    }
    _attempt = 0;
    _reconnectTimer?.cancel();
    _open();
  }

  void suspend() {
    _suspended = true;
    _reconnectTimer?.cancel();
    _closeChannel();
    _setStatus(MessagingStatus.disconnected);
  }

  void disconnect() {
    _reconnectTimer?.cancel();
    _url = null;
    _uniqueId = null;
    _password = null;
    _attempt = 0;
    _closeChannel();
    _setStatus(MessagingStatus.disconnected);
  }

  void _closeChannel() {
    _authTimer?.cancel();
    _authPending = false;
    _failAllWaiters();
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close(ws_status.normalClosure);
    _channel = null;
  }

  void _failAllWaiters() {
    for (final waiters in _ackWaiters.values) {
      for (final waiter in waiters) {
        if (!waiter.isCompleted) {
          waiter.completeError(const MessagingFailure());
        }
      }
    }
    _ackWaiters.clear();
    _friendsWaiter?.completeError(const MessagingFailure());
    _friendsWaiter = null;
  }

  void _setStatus(MessagingStatus value) {
    if (_status == value) return;
    _status = value;
    _statusController.add(value);
  }

  Future<void> dispose() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    _authTimer?.cancel();
    _failAllWaiters();
    await _subscription?.cancel();
    await _channel?.sink.close(ws_status.normalClosure);
    await _statusController.close();
    await _friendsController.close();
    await _invitesController.close();
    await _responsesController.close();
    await _requestsController.close();
    await _updatesController.close();
    await _pushesController.close();
  }

}
