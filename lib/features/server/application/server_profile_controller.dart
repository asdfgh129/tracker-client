import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/server_profile.dart';
import '../../../core/network/traccar_api.dart';
import '../../../core/observability/logger.dart';
import '../../../core/providers.dart';
import '../../../core/push/push_service.dart';
import '../../../core/storage/database.dart';
import '../../../core/storage/secure_store.dart';
import '../../../domain/failures.dart';
import '../../auth/application/session_controller.dart';

/// 连接测试结果（docs/02 §3.2 表格：成功/401/TLS/超时/非 Traccar）。
enum ProbeOutcome { ok, reachableNeedsAuth, timeout, tls, notTraccar, networkError }

class ProbeResult {
  const ProbeResult({
    required this.outcome,
    this.serverName,
    this.version,
    this.latencyMs,
    this.detail,
  });

  final ProbeOutcome outcome;
  final String? serverName;
  final String? version;
  final int? latencyMs;
  final String? detail;

  bool get isTraccar => outcome == ProbeOutcome.ok || outcome == ProbeOutcome.reachableNeedsAuth;
}

class ServerProfileState {
  const ServerProfileState({this.profiles = const [], this.active});

  final List<ServerProfileRow> profiles;
  final ServerProfileRow? active;

  /// 供网络层使用的领域视图。
  ServerProfile? get activeProfile {
    final row = active;
    if (row == null) return null;
    return ServerProfile(
      id: row.id,
      name: row.name,
      apiBaseUrl: row.apiBaseUrl,
      reportUrl: row.reportUrl,
      allowSelfSigned: row.allowSelfSigned,
      allowInsecure: row.allowInsecure,
      isDemo: row.isDemo,
      isActive: row.isActive,
    );
  }

  ServerProfileState copyWith({
    List<ServerProfileRow>? profiles,
    ServerProfileRow? active,
    bool clearActive = false,
  }) {
    return ServerProfileState(
      profiles: profiles ?? this.profiles,
      active: clearActive ? null : (active ?? this.active),
    );
  }
}

/// 服务器档案控制器（AUTH-01/02/03/09/11）。
class ServerProfileController extends AsyncNotifier<ServerProfileState> {
  @override
  Future<ServerProfileState> build() async {
    final db = ref.watch(appDatabaseProvider);
    final profiles = await db.allProfiles();
    var active = profiles.where((p) => p.isActive).firstOrNull;
    active ??= await db.activeProfile();
    return ServerProfileState(profiles: profiles, active: active);
  }

  /// 测试连接（不落库，docs/02 §3.2）。
  Future<ProbeResult> probe(ServerProfile profile) async {
    final api = TraccarApi(profile: profile);
    final watch = Stopwatch()..start();
    try {
      final server = await api.getServer();
      watch.stop();
      // 字段提取见 ServerInfo（attributes 为嵌套对象，顶层不存在）。
      return ProbeResult(
        outcome: ProbeOutcome.ok,
        serverName: server['name']?.toString(),
        version: ServerInfo.versionOf(server),
        latencyMs: watch.elapsedMilliseconds,
      );
    } on DioException catch (error) {
      watch.stop();
      return _probeFromError(error, watch.elapsedMilliseconds);
    } on AppFailure catch (error) {
      return _probeFromFailure(error);
    } finally {
      // 探测用完即弃，不保留 Cookie。
    }
  }

  ProbeResult _probeFromError(DioException error, int latencyMs) {
    final status = error.response?.statusCode;
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout) {
      return const ProbeResult(outcome: ProbeOutcome.timeout);
    }
    if (error.type == DioExceptionType.badCertificate) {
      return const ProbeResult(
        outcome: ProbeOutcome.tls,
        detail: '证书不受信任，请检查域名与证书；自建服务器可在高级选项中允许自签名',
      );
    }
    if (error.type == DioExceptionType.connectionError) {
      return ProbeResult(
        outcome: ProbeOutcome.networkError,
        detail: '无法连接：${error.message ?? '网络不可达'}',
      );
    }
    if (status == 401 || status == 403) {
      return ProbeResult(
        outcome: ProbeOutcome.reachableNeedsAuth,
        latencyMs: latencyMs,
      );
    }
    if (status != null && status >= 400) {
      return ProbeResult(
        outcome: ProbeOutcome.networkError,
        detail: 'HTTP $status',
      );
    }
    return ProbeResult(outcome: ProbeOutcome.networkError, detail: error.message);
  }

  ProbeResult _probeFromFailure(AppFailure error) {
    if (error is TimeoutFailure) return const ProbeResult(outcome: ProbeOutcome.timeout);
    if (error is UnauthorizedFailure || error is ForbiddenFailure) {
      return const ProbeResult(outcome: ProbeOutcome.reachableNeedsAuth);
    }
    if (error is ValidationFailure) {
      return ProbeResult(outcome: ProbeOutcome.notTraccar, detail: error.message);
    }
    return ProbeResult(outcome: ProbeOutcome.networkError, detail: error.message);
  }

  /// 保存档案并激活。同地址幂等（更新而不是新增）。
  Future<void> saveProfile(ServerProfile profile) async {
    final db = ref.watch(appDatabaseProvider);
    final profiles = await db.allProfiles();
    final existing = profiles.where((p) => p.apiBaseUrl == profile.apiBaseUrl).firstOrNull;
    if (existing != null) {
      await db.updateProfile(
        existing.copyWith(
          name: profile.name,
          apiBaseUrl: profile.apiBaseUrl,
          reportUrl: profile.reportUrl,
          allowSelfSigned: profile.allowSelfSigned,
          allowInsecure: profile.allowInsecure,
          isDemo: profile.isDemo,
        ),
      );
      await db.activateProfile(existing.id);
    } else {
      final id = await db.insertProfile(
        ServerProfilesCompanion.insert(
          name: profile.name,
          apiBaseUrl: profile.apiBaseUrl,
          reportUrl: profile.reportUrl,
          allowSelfSigned: Value(profile.allowSelfSigned),
          allowInsecure: Value(profile.allowInsecure),
          isDemo: Value(profile.isDemo),
          sortOrder: Value(profiles.length),
        ),
      );
      await db.activateProfile(id);
    }
    await _reload();
  }

  /// 激活已有档案（多服务器切换，AUTH-09）。
  Future<void> activate(int id) async {
    final db = ref.watch(appDatabaseProvider);
    // 换服务器前撤销旧服务器的推送网关别名（必须在会话失效之前，
    // 盐值还在；docs/09 §3.4 防串号）。
    await _deleteAliasBestEffort();
    await db.activateProfile(id);
    // 只结束当前内存会话；其它服务器的 Token / 密码 / 盐必须保留，
    // 否则多服务器用户每次切换都要全部重新登录。
    await ref.read(sessionControllerProvider.notifier).expireSession();
    await _reload();
  }

  Future<void> _deleteAliasBestEffort() async {
    try {
      final session = ref.read(sessionControllerProvider).valueOrNull;
      final userId = session?.user?.id;
      final serverId = session?.profile?.id;
      if (userId == null || serverId == null) return;
      final salt =
          await ref.read(secureStoreProvider).read(aliasSaltKey(serverId));
      await deleteGatewayAliasFor(
        userId: userId,
        serverId: serverId,
        salt: salt,
        sessionToken: session?.token,
      );
    } on Object catch (error) {
      AppLog.w('push', 'alias delete failed (ignored): $error');
    }
  }

  Future<void> deleteProfile(int id) async {
    final db = ref.watch(appDatabaseProvider);
    final wasActive =
        ref.read(sessionControllerProvider).valueOrNull?.profile?.id == id;
    await db.deleteProfile(id);
    await db.wipeServerData(id);
    await db.clearTrackingSnapshots(id);
    // 按 serverId 精确清理该档案的全部凭据（不能只删 Token）。
    final secure = ref.read(secureStoreProvider);
    await secure.delete(SecureKeys.token(id));
    await secure.delete(SecureKeys.password(id));
    await secure.delete(SecureKeys.messagingPassword(id));
    await secure.delete(SecureKeys.commandSecret(id));
    await secure.delete(aliasSaltKey(id));
    if (wasActive) {
      await ref.read(sessionControllerProvider.notifier).expireSession();
    }
    await _reload();
  }

  Future<void> _reload() async {
    final db = ref.watch(appDatabaseProvider);
    final profiles = await db.allProfiles();
    final active = profiles.where((p) => p.isActive).firstOrNull;
    state = AsyncData(ServerProfileState(profiles: profiles, active: active));
  }
}

final serverProfileControllerProvider =
    AsyncNotifierProvider<ServerProfileController, ServerProfileState>(
  ServerProfileController.new,
);

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
