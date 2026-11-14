import 'dart:async';
import 'dart:math' as math;

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/messaging_client.dart';
import '../../../core/observability/logger.dart';
import '../../../core/providers.dart';
import '../../../core/storage/database.dart';
import '../../../core/storage/preferences.dart';
import '../../../core/storage/secure_store.dart';
import '../../../domain/entities/models.dart';
import '../../auth/application/session_controller.dart';
import '../../devices/application/devices_controller.dart';
import '../../tracking/application/self_device_binder.dart';

/// 好友体系 UI 状态（好友列表本体走 [friendsListProvider] 的 db 流）。
class FriendsState {
  const FriendsState({
    this.channelStatus = MessagingStatus.disconnected,
    this.pendingInvite,
    this.pendingRequest,
    this.channelError,
  });

  final MessagingStatus channelStatus;

  /// 实时收到的好友申请（处理前常驻提示）。
  final FriendInvite? pendingInvite;

  /// 收到的实时定位请求（全局弹窗）。
  final IncomingLocationRequest? pendingRequest;

  /// 通道认证失败等原因（UI 常驻提示）。
  final String? channelError;

  FriendsState copyWith({
    MessagingStatus? channelStatus,
    FriendInvite? pendingInvite,
    bool clearInvite = false,
    IncomingLocationRequest? pendingRequest,
    bool clearRequest = false,
    String? channelError,
    bool clearError = false,
  }) {
    return FriendsState(
      channelStatus: channelStatus ?? this.channelStatus,
      pendingInvite: clearInvite ? null : (pendingInvite ?? this.pendingInvite),
      pendingRequest:
          clearRequest ? null : (pendingRequest ?? this.pendingRequest),
      channelError: clearError ? null : (channelError ?? this.channelError),
    );
  }
}

/// 好友体系控制器（FRI，docs：好友互见 + 实时定位请求）。
///
/// 职责：
/// - 会话就绪后建立 5056 连接（uniqueId + 设备密码，首次自动注册密码）；
/// - 把服务端推送（好友申请/响应/位置广播）落库并转成 UI 状态；
/// - 提供加好友 / 处理邀请 / 发起与回应定位请求的应用层 API。
class FriendsController extends Notifier<FriendsState> {
  bool _bound = false;
  bool _disposed = false;
  String? _connectionKey;
  String? _freshPassword;
  final Map<int, Completer<LocationPushResult>> _pushWaiters = {};

  @override
  FriendsState build() {
    ref.onDispose(_teardownAll);
    final session = ref.watch(sessionControllerProvider).valueOrNull;
    if (session == null || !session.isAuthenticated || session.profile == null) {
      _teardownConnection();
      return const FriendsState();
    }
    _bindStreams();
    _ensureConnection(session);
    return const FriendsState();
  }

  // ---- 连接管理 ----

  void _bindStreams() {
    if (_bound) return;
    _bound = true;
    final client = ref.read(messagingClientProvider);
    client.statusStream.listen((status) {
      if (status == MessagingStatus.connected) {
        _onConnected();
      }
      _updateState(FriendsState(
        channelStatus: status,
        pendingInvite: state.pendingInvite,
        pendingRequest: state.pendingRequest,
        channelError: status == MessagingStatus.failed
            ? '消息通道认证失败（设备密码不匹配）。如本机重装过应用，请联系管理员清除设备密码后重试'
            : state.channelError,
      ));
    });
    client.friendsStream.listen((entries) async {
      final serverId = _serverId();
      if (serverId == null) return;
      await ref.read(appDatabaseProvider).upsertFriends(
            serverId,
            entries.map(_toRow),
          );
    });
    client.invitesStream.listen((invite) {
      _updateState(state.copyWith(
        pendingInvite: invite,
        channelStatus: state.channelStatus,
      ));
    });
    client.responsesStream.listen((response) async {
      await _refreshFriends();
      AppLog.i('friends',
          'friend ${response.action}: ${response.fromUniqueId}');
    });
    client.requestsStream.listen((request) {
      _updateState(state.copyWith(
        pendingRequest: request,
        channelStatus: state.channelStatus,
      ));
    });
    client.updatesStream.listen((update) async {
      final serverId = _serverId();
      if (serverId == null) return;
      await ref.read(appDatabaseProvider).updateFriendPosition(
            serverId,
            update.fromUniqueId,
            deviceId: update.fromDeviceId,
            latitude: update.latitude,
            longitude: update.longitude,
            lastTime: (update.time ?? DateTime.now().toUtc())
                .millisecondsSinceEpoch,
          );
    });
    client.pushesStream.listen((result) {
      final waiter = _pushWaiters.remove(result.requestId);
      if (waiter != null && !waiter.isCompleted) {
        waiter.complete(result);
      }
    });
  }

  Future<void> _ensureConnection(SessionState session) async {
    final profile = session.profile;
    final serverId = profile?.id;
    if (profile == null || serverId == null) return;
    try {
      // 本机身份：uniqueId 未生成则生成并绑定服务端设备。
      final binder = ref.read(selfDeviceBinderProvider);
      final uniqueId = await binder.ensureUniqueId();
      if (binder.boundDeviceId() == null) {
        await binder.bind();
      }

      final secure = ref.read(secureStoreProvider);
      final stored = await secure.read(SecureKeys.messagingPassword(serverId));
      final key = '${profile.messagingUrl}|$uniqueId|${stored != null}';
      if (_connectionKey == key &&
          ref.read(messagingClientProvider).status !=
              MessagingStatus.disconnected) {
        return;
      }
      _connectionKey = key;
      if (stored != null) {
        _freshPassword = null;
        ref.read(messagingClientProvider).connect(
              url: profile.messagingUrl,
              uniqueId: uniqueId,
              password: stored,
            );
      } else {
        // 设备尚未设置密码：先无密码认证，成功后注册随机密码。
        _freshPassword = _generatePassword();
        ref.read(messagingClientProvider).connect(
              url: profile.messagingUrl,
              uniqueId: uniqueId,
            );
      }
    } on Object catch (error) {
      AppLog.w('friends', 'messaging connect setup failed: $error');
      _updateState(state.copyWith(
        channelError: '消息通道不可用：$error',
        channelStatus: state.channelStatus,
      ));
    }
  }

  /// 认证成功后：注册待设置的设备密码并刷新好友列表。
  Future<void> _onConnected() async {
    final fresh = _freshPassword;
    final serverId = _serverId();
    if (fresh != null && serverId != null) {
      try {
        await ref.read(messagingClientProvider).setPassword(password: fresh);
        await ref
            .read(secureStoreProvider)
            .write(SecureKeys.messagingPassword(serverId), fresh);
        _freshPassword = null;
        AppLog.i('friends', 'messaging device password registered');
      } on Object catch (error) {
        AppLog.w('friends', 'device password register failed: $error');
      }
    }
    await _refreshFriends();
  }

  Future<void> _refreshFriends() async {
    try {
      await ref.read(messagingClientProvider).listFriends();
    } on Object catch (error) {
      AppLog.w('friends', 'friends.list failed: $error');
    }
  }

  /// 好友邀请推送唤醒触发的列表刷新（公开给 app 层）。
  ///
  /// 通道未就绪时静默失败无害：连接成功后 `_onConnected` 会再拉一次。
  Future<void> refreshFromPush() => _refreshFriends();

  // ---- 应用层 API ----

  /// 加好友（输入对方 8 位 uniqueId）。返回服务器状态（pending/accepted）。
  Future<String> addFriend(String uniqueId) async {
    final status = await ref
        .read(messagingClientProvider)
        .requestFriend(uniqueId.trim());
    await _refreshFriends();
    return status;
  }

  /// 同意当前收到的申请。
  Future<void> acceptInvite() async {
    final invite = state.pendingInvite;
    if (invite == null) return;
    _updateState(state.copyWith(clearInvite: true));
    try {
      await ref.read(messagingClientProvider).acceptFriend(invite.fromUniqueId);
    } finally {
      await _refreshFriends();
    }
  }

  /// 拒绝当前收到的申请。
  Future<void> rejectInvite() async {
    final invite = state.pendingInvite;
    if (invite == null) return;
    _updateState(state.copyWith(clearInvite: true));
    try {
      await ref.read(messagingClientProvider).rejectFriend(invite.fromUniqueId);
    } finally {
      await _refreshFriends();
    }
  }

  /// 同意好友页列表中的申请（按 uniqueId）。
  Future<void> acceptFriendById(String uniqueId) async {
    try {
      await ref.read(messagingClientProvider).acceptFriend(uniqueId);
    } finally {
      await _refreshFriends();
    }
  }

  /// 拒绝好友页列表中的申请（按 uniqueId）。
  Future<void> rejectFriendById(String uniqueId) async {
    try {
      await ref.read(messagingClientProvider).rejectFriend(uniqueId);
    } finally {
      await _refreshFriends();
    }
  }

  /// 删除好友。
  Future<void> removeFriend(String uniqueId) async {
    await ref.read(messagingClientProvider).removeFriend(uniqueId);
    await _refreshFriends();
  }

  /// 请求对方实时位置。返回最终状态字符串：
  /// `position`（成功，位置已落库）/ `timeout` / `declined` / `offline`。
  Future<String> requestRealtimeLocation(String uniqueId) async {
    final client = ref.read(messagingClientProvider);
    final ack = await client.requestLocation(uniqueId, timeoutSeconds: 30);
    if (ack.status == 'offline') {
      final serverId = _serverId();
      if (serverId != null && ack.latitude != null && ack.longitude != null) {
        await ref.read(appDatabaseProvider).updateFriendPosition(
              serverId,
              uniqueId,
              latitude: ack.latitude!,
              longitude: ack.longitude!,
              lastTime: (ack.lastTime ?? DateTime.now().toUtc())
                  .millisecondsSinceEpoch,
            );
      }
      return 'offline';
    }
    final completer = Completer<LocationPushResult>();
    _pushWaiters[ack.requestId] = completer;
    try {
      final result = await completer.future.timeout(
        const Duration(seconds: 35),
        onTimeout: () => LocationPushResult(
          requestId: ack.requestId,
          status: 'timeout',
        ),
      );
      final serverId = _serverId();
      if (serverId != null &&
          result.latitude != null &&
          result.longitude != null) {
        await ref.read(appDatabaseProvider).updateFriendPosition(
              serverId,
              uniqueId,
              deviceId: result.fromDeviceId,
              latitude: result.latitude!,
              longitude: result.longitude!,
              lastTime: (result.time ?? DateTime.now().toUtc())
                  .millisecondsSinceEpoch,
            );
      }
      return result.latitude != null ? 'position' : (result.status ?? 'timeout');
    } finally {
      _pushWaiters.remove(ack.requestId);
    }
  }

  /// 回应收到的定位请求（同意 → 携本机最新位置；拒绝 → declined）。
  Future<void> respondRequest({required bool accept}) async {
    final request = state.pendingRequest;
    if (request == null) return;
    _updateState(state.copyWith(clearRequest: true));
    final client = ref.read(messagingClientProvider);
    if (!accept) {
      await client.declineLocation(request.requestId);
      return;
    }
    final position = _latestOwnPosition();
    if (position == null) {
      await client.declineLocation(request.requestId);
      return;
    }
    await client.replyLocation(
      request.requestId,
      latitude: position.latitude,
      longitude: position.longitude,
      accuracy: position.accuracy,
      speed: position.speedMetersPerSecond,
    );
  }

  /// 本机最新位置：优先 REST/WS 合并缓存，其次 drift 库。
  Position? _latestOwnPosition() {
    final deviceId = ref.read(prefsProvider).getInt(PrefKeys.trackingDeviceId);
    final devices = ref.read(devicesControllerProvider).valueOrNull;
    if (deviceId != null) {
      final cached = devices?.positionOf(deviceId);
      if (cached != null) return cached;
    }
    return null;
  }

  // ---- helpers ----

  int? _serverId() =>
      ref.read(sessionControllerProvider).valueOrNull?.profile?.id;

  FriendRowsCompanion _toRow(FriendEntry entry) {
    return FriendRowsCompanion.insert(
      serverId: _serverId() ?? 0,
      uniqueId: entry.uniqueId,
      status: entry.status,
      deviceId: Value(entry.deviceId),
      name: Value(entry.name),
      online: Value(entry.online),
      lastLatitude: Value(entry.latitude),
      lastLongitude: Value(entry.longitude),
      lastTime: Value(entry.lastTime?.millisecondsSinceEpoch),
      updatedAt: Value(DateTime.now().toUtc()),
    );
  }

  void _updateState(FriendsState next) {
    if (!_disposed) state = next;
  }

  void _teardownConnection() {
    _connectionKey = null;
    _freshPassword = null;
    if (!_disposed) {
      ref.read(messagingClientProvider).disconnect();
    }
  }

  void _teardownAll() {
    _disposed = true;
    _bound = false;
    _teardownConnection();
  }

  static String _generatePassword() {
    const alphabet =
        'abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = math.Random.secure();
    return List.generate(
      12,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();
  }
}

final messagingClientProvider = Provider<MessagingClient>((ref) {
  final client = MessagingClient();
  ref.onDispose(client.dispose);
  return client;
});

final friendsControllerProvider =
    NotifierProvider<FriendsController, FriendsState>(FriendsController.new);

/// 好友列表（db 响应式流；登录态变化自动失效）。
final friendsListProvider = StreamProvider<List<FriendRow>>((ref) {
  final session = ref.watch(sessionControllerProvider).valueOrNull;
  final serverId = session?.profile?.id;
  if (serverId == null) return Stream.value(const <FriendRow>[]);
  return ref.watch(appDatabaseProvider).watchFriends(serverId);
});
