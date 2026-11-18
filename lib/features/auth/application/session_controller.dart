import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart' as local_auth;

import '../../../core/network/server_profile.dart';
import '../../../core/network/socket_client.dart';
import '../../../core/network/traccar_api.dart';
import '../../../core/observability/logger.dart';
import '../../../core/providers.dart';
import '../../../core/push/push_service.dart';
import '../../../core/storage/preferences.dart';
import '../../../core/storage/secure_store.dart';
import '../../../domain/entities/models.dart';
import '../../../domain/failures.dart';
import '../../server/application/server_profile_controller.dart';
import '../../settings/application/settings_controller.dart';

enum SessionPhase {
  /// 启动中：正在恢复会话（路由守卫等待此阶段结束）。
  restoring,

  /// 未认证。
  anonymous,

  /// 已认证。
  authenticated,
}

/// OIDC 回跳目标（与服务端白名单 `OpenIdAppRedirect.APP_REDIRECT_URI` 一致，
/// Android/iOS 已注册 trackerone scheme）。
const String openIdAppRedirectUri = 'trackerone://openid/callback';

/// 构建 OIDC 企业登录授权入口 URL（系统浏览器打开，docs/04 §2.3）。
///
/// redirect 经服务端签名 state 经 IdP 往返带回（防篡改），回调由
/// [handleOpenIdCallback] 处理。
Uri buildOpenIdAuthUrl(String apiBaseUrl) {
  return Uri.parse('$apiBaseUrl/api/session/openid/auth').replace(
    queryParameters: {'redirect': openIdAppRedirectUri},
  );
}

/// 从 OIDC 回跳深链提取一次性 code；形状不符返回 null。
String? openIdCodeFromUri(Uri uri) {
  if (uri.scheme != 'trackerone' || uri.host != 'openid') return null;
  if (uri.pathSegments.isEmpty || uri.pathSegments.first != 'callback') {
    return null;
  }
  final code = uri.queryParameters['code'];
  if (code == null || code.isEmpty) return null;
  return code;
}

/// 会话状态（docs/03 §15.1）。
class SessionState {
  const SessionState({
    required this.phase,
    this.token,
    this.user,
    this.profile,
    this.serverVersion,
    this.offline = false,
    this.readOnly = false,
    this.unlocked = true,
    this.biometricEnabled = false,
    this.apiClient,
  });

  final SessionPhase phase;

  /// Secure Storage 中的 Token 内存副本；不落日志、不进 SharedPreferences。
  final String? token;
  final Account? user;
  final ServerProfile? profile;

  /// 能力探测结果（AUTH-11）。
  final String? serverVersion;

  /// 网络不可达时用缓存进入只读界面（docs/01 §3.2 验收）。
  final bool offline;

  /// 离线只读：未登录但允许浏览本地缓存（网络调用一律拒绝）。
  final bool readOnly;

  /// 生物识别锁（AUTH-07）：false 时路由守卫拦截到 /lock。
  final bool unlocked;
  final bool biometricEnabled;

  /// 与会话绑定的 REST 客户端（Bearer 随 token 刷新）。
  final TraccarApi? apiClient;

  bool get isAuthenticated => phase == SessionPhase.authenticated;

  /// 应用层 API 门面。
  ///
  /// M-8：会话未就绪、或生物识别锁定期间一律拒绝 —— 让「锁」成为真正的
  /// 数据访问门禁，而不只是路由重定向。
  TraccarApi api() {
    if (readOnly) {
      throw const UnauthorizedFailure(message: '离线只读模式，请登录后再操作');
    }
    if (!unlocked) {
      throw const UnauthorizedFailure(message: '应用已锁定，请先解锁');
    }
    final client = apiClient;
    if (client == null) {
      throw const ConfigFailure('会话未就绪');
    }
    return client;
  }

  SessionState copyWith({
    SessionPhase? phase,
    String? token,
    bool clearToken = false,
    Account? user,
    bool clearUser = false,
    ServerProfile? profile,
    bool clearProfile = false,
    String? serverVersion,
    bool? offline,
    bool? readOnly,
    bool? unlocked,
    bool? biometricEnabled,
    TraccarApi? apiClient,
  }) {
    return SessionState(
      phase: phase ?? this.phase,
      token: clearToken ? null : (token ?? this.token),
      user: clearUser ? null : (user ?? this.user),
      profile: clearProfile ? null : (profile ?? this.profile),
      serverVersion: serverVersion ?? this.serverVersion,
      offline: offline ?? this.offline,
      readOnly: readOnly ?? this.readOnly,
      unlocked: unlocked ?? this.unlocked,
      biometricEnabled: biometricEnabled ?? this.biometricEnabled,
      apiClient: apiClient ?? this.apiClient,
    );
  }
}

/// 会话控制器：恢复、密码登录、Token 登录、登出。
///
/// 401 处理：AuthInterceptor 回调 [expireSession]，清 Token 回登录页；
/// 网络错误不强制登出（docs/01 §3.2）。
class SessionController extends AsyncNotifier<SessionState> {
  TraccarApi? _api;

  /// OIDC 回跳在会话恢复（build）完成前到达时的暂存（冷启动深链）。
  _PendingOpenId? _pendingOpenId;

  @override
  Future<SessionState> build() async {
    final serverState = ref.watch(serverProfileControllerProvider).value;
    final profile = serverState?.activeProfile;
    final prefs = ref.watch(prefsProvider);

    // 恢复：有档案 + 有 Token → 校验；失败降级只读（offline）。
    final serverId = profile?.id;
    if (profile == null || serverId == null) {
      return _finalize(SessionState(phase: SessionPhase.anonymous, profile: profile));
    }

    final secure = ref.read(secureStoreProvider);
    final token = await secure.read(SecureKeys.token(serverId));
    if (token == null || token.isEmpty) {
      return _finalize(SessionState(phase: SessionPhase.anonymous, profile: profile));
    }

    // 生物识别锁在 UI 层拦截进入主界面；会话本身仍是已认证。
    final restored = await _restoreUser(profile, token);
    if (restored.unauthorized) {
      // Token 已被撤销/过期：清掉凭据并回登录页，绝不能把 401 当成离线。
      return _finalize(
        SessionState(phase: SessionPhase.anonymous, profile: profile),
      );
    }
    final user = restored.user;
    _api = _createApi(profile, token);
    final biometricEnabled = prefs.getBool(SecureKeys.biometricEnabled) ?? false;
    final unlocked = !biometricEnabled;
    if (user == null) {
      // 离线降级：仅网络不可达时才允许用缓存进入只读（docs/01 §3.2）。
      final offlineApi = _createApi(profile, token);
      _api = offlineApi;
      return _finalize(SessionState(
        phase: SessionPhase.authenticated,
        token: token,
        profile: profile,
        offline: true,
        unlocked: unlocked,
        biometricEnabled: biometricEnabled,
        apiClient: offlineApi,
      ));
    }
    final restoredApi = _createApi(profile, token);
    _api = restoredApi;
    return _finalize(SessionState(
      phase: SessionPhase.authenticated,
      token: token,
      user: user,
      profile: profile,
      offline: false,
      unlocked: unlocked,
      biometricEnabled: biometricEnabled,
      serverVersion: _cachedVersion(prefs),
      apiClient: restoredApi,
    ));
  }

  /// 消费会话恢复完成前暂存的 OIDC 回调（冷启动深链，docs/04 §2.3）。
  SessionState _finalize(SessionState result) {
    final pending = _pendingOpenId;
    if (pending != null) {
      _pendingOpenId = null;
      unawaited(_completeOpenIdLogin(pending.code, result, pending.completer));
    }
    return result;
  }

  /// 生物识别解锁成功后调用。
  ///
  /// M-8：未解锁前 [SessionState.api] 拒绝服务（见 SessionState.api），
  /// 因此远程指令、数据同步等控制面在锁定期间都不可用 —— 不只是 UI 拦截。
  Future<void> unlock() async {
    final current = state.value;
    if (current != null) {
      state = AsyncData(current.copyWith(unlocked: true));
    }
  }

  /// 主动上锁（设置页 / 退到后台可选行为）。
  Future<void> lock() async {
    final current = state.value;
    if (current != null && current.biometricEnabled) {
      state = AsyncData(current.copyWith(unlocked: false));
    }
  }

  /// 进入离线只读模式（不登录浏览本地缓存，docs/01 §3.2）。
  ///
  /// 界面只读 drift 缓存；[SessionState.api] 拒绝一切网络调用。
  void enterReadOnly() {
    final profile = state.value?.profile ??
        ref
            .read(serverProfileControllerProvider)
            .valueOrNull
            ?.activeProfile;
    _api = null;
    state = AsyncData(SessionState(
      phase: SessionPhase.anonymous,
      profile: profile,
      offline: true,
      readOnly: true,
    ));
  }

  /// 开关生物识别锁（AUTH-07）。
  Future<void> setBiometricEnabled(bool enabled) async {
    await ref.read(prefsProvider).setBool(SecureKeys.biometricEnabled, enabled);
    final current = state.value;
    if (current != null) {
      state = AsyncData(
        current.copyWith(biometricEnabled: enabled, unlocked: !enabled),
      );
    }
  }

  static String? _cachedVersion(Prefs prefs) =>
      prefs.getString('app.serverVersion');

  TraccarApi _createApi(ServerProfile profile, String? token) {
    final api = TraccarApi(
      profile: profile,
      token: token,
      onUnauthorized: expireSession,
    );
    return api;
  }

  /// 应用层 API 门面：UI 与其他 feature 统一从这里取（不直接 new Dio）。
  TraccarApi api() {
    final current = state.value;
    final profile = current?.profile;
    if (profile == null) {
      throw const ConfigFailure('未配置服务器档案');
    }
    _api ??= _createApi(profile, current?.token);
    _api!.updateToken(current?.token);
    return _api!;
  }

  /// SessionState.api() 的委托目标：保持调用侧 `state.api()` 语义。
  TraccarApi apiFor(SessionState session) {
    final profile = session.profile;
    if (profile == null) {
      throw const ConfigFailure('未配置服务器档案');
    }
    _api ??= _createApi(profile, session.token);
    _api!.updateToken(session.token);
    return _api!;
  }

  /// 恢复会话并区分「网络不可达」与「凭据失效」。
  ///
  /// 返回 `unauthorized = true` 表示服务端明确拒绝（401），调用方必须回登录页；
  /// 只有 `user == null && !unauthorized` 才允许离线降级。
  Future<({Account? user, bool unauthorized})> _restoreUser(
    ServerProfile profile,
    String token,
  ) async {
    try {
      final api = _createApi(profile, token);
      final user = await api.currentUser();
      AppLog.i('auth', 'session restored');
      return (user: user, unauthorized: false);
    } on AppFailure catch (error) {
      // 网络错误：离线降级；401：清会话。
      AppLog.w('auth', 'restore failed: ${error.code ?? 'no-code'}');
      if (error is UnauthorizedFailure) {
        await _clearToken(profile);
        return (user: null, unauthorized: true);
      }
      return (user: null, unauthorized: false);
    } on Object catch (error) {
      AppLog.w('auth', 'restore crashed: $error');
      return (user: null, unauthorized: false);
    }
  }

  /// 密码登录（AUTH-04/05）。
  ///
  /// 服务端开启 TOTP 时首次调用抛 [TotpRequiredFailure]；
  /// UI 收集验证码后携带 [totpCode] 重试。
  Future<void> loginWithPassword({
    required String email,
    required String password,
    bool rememberPassword = false,
    String? totpCode,
  }) async {
    final profile = state.value?.profile;
    if (profile == null || profile.id == null) {
      throw const ConfigFailure('请先配置服务器');
    }
    try {
      final api = _createApi(profile, null);
      final user = await api.login(email, password, code: totpCode);
      final token = await api.exchangeToken();
      final secure = ref.read(secureStoreProvider);
      await secure.write(SecureKeys.token(profile.id!), token);
      if (rememberPassword) {
        await secure.write(SecureKeys.password(profile.id!), password);
      } else {
        await secure.delete(SecureKeys.password(profile.id!));
      }
      _api = api;
      state = AsyncData(
        state.value!.copyWith(
          phase: SessionPhase.authenticated,
          token: token,
          user: user,
          offline: false,
          apiClient: api,
        ),
      );
      await _registerPushAlias(user);
      AppLog.i('auth', 'login ok (server=${profile.id})');
    } on AppFailure {
      rethrow;
    }
  }

  /// 生物识别可用性探测（设置页展示开关前调用）。
  Future<bool> biometricAvailable() async {
    try {
      final auth = local_auth.LocalAuthentication();
      return await auth.canCheckBiometrics || await auth.isDeviceSupported();
    } on Object {
      return false;
    }
  }

  /// 执行一次生物识别验证。
  Future<bool> authenticateWithBiometrics() async {
    try {
      final auth = local_auth.LocalAuthentication();
      return await auth.authenticate(
        localizedReason: 'unlock TrackerOne',
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
    } on Object {
      return false;
    }
  }

  /// Token 直接登录（AUTH-06，企业分发 / 扫码）。
  Future<void> loginWithToken(String token) async {
    final profile = state.value?.profile;
    if (profile == null || profile.id == null) {
      throw const ConfigFailure('请先配置服务器');
    }
    final api = _createApi(profile, token);
    try {
      final user = await api.validateToken(token);
      await ref
          .read(secureStoreProvider)
          .write(SecureKeys.token(profile.id!), token);
      _api = api;
      state = AsyncData(
        state.value!.copyWith(
          phase: SessionPhase.authenticated,
          token: token,
          user: user,
          offline: false,
          apiClient: api,
        ),
      );
      await _registerPushAlias(user);
    } on AppFailure {
      rethrow;
    }
  }

  /// 处理 OIDC 回跳深链（`trackerone://openid/callback?code=...`，0.5.0）。
  ///
  /// 返回登录是否成功；app 层据此导航。会话恢复中到达的回调（冷启动深链）
  /// 暂存至 [_pendingOpenId]，build 完成后由 [_finalize] 自动消费——
  /// 返回的 Future 在两种场景下都会完成。
  Future<bool> handleOpenIdCallback(Uri uri) {
    final code = openIdCodeFromUri(uri);
    if (code == null) {
      AppLog.w('auth', 'ignored malformed openid callback');
      return Future<bool>.value(false);
    }
    if (state.isLoading) {
      AppLog.i('auth', 'openid callback while restoring: queued');
      final completer = Completer<bool>();
      _pendingOpenId = _PendingOpenId(code, completer);
      return completer.future;
    }
    return _completeOpenIdLogin(code, state.value!, null);
  }

  /// OIDC 登录完成段：一次性 code 换长期 Token → 校验 → 落库 → 建会话 →
  /// 注册推送别名。失败不抛出（深链场景无处展示异常），返回 false。
  Future<bool> _completeOpenIdLogin(
    String code,
    SessionState base,
    Completer<bool>? completer,
  ) async {
    try {
      final profile = base.profile;
      final serverId = profile?.id;
      if (profile == null || serverId == null) {
        throw const ConfigFailure('请先配置服务器');
      }
      final api = _createApi(profile, null);
      final token = await api.exchangeOpenIdCode(code);
      final user = await api.validateToken(token);
      await ref.read(secureStoreProvider).write(SecureKeys.token(serverId), token);
      _api = api;
      state = AsyncData(base.copyWith(
        phase: SessionPhase.authenticated,
        token: token,
        user: user,
        offline: false,
        apiClient: api,
      ));
      await _registerPushAlias(user);
      AppLog.i('auth', 'openid login ok (server=$serverId)');
      completer?.complete(true);
      return true;
    } on AppFailure catch (error) {
      AppLog.w('auth', 'openid login failed: ${error.code ?? '-'}');
      completer?.complete(false);
      return false;
    }
  }

  /// 探测服务器版本与坐标系模式（进主界面后刷新，AUTH-11）。
  ///
  /// 字段提取见 `ServerInfo`（attributes 为嵌套对象，顶层不存在）。
  Future<void> refreshServerInfo() async {
    final profile = state.value?.profile;
    if (profile == null) return;
    try {
      final server = await apiFor(state.value!).getServer();
      final version = ServerInfo.versionOf(server);
      final coordinateSystem = ServerInfo.coordinateSystemOf(server);
      final prefs = ref.read(prefsProvider);
      if (version != null) await prefs.setString(PrefKeys.serverVersion, version);
      if (coordinateSystem != null) {
        await prefs.setString(PrefKeys.serverCoordinateSystem, coordinateSystem);
      }
      state = AsyncData(state.value!.copyWith(serverVersion: version, offline: false));
    } on AppFailure catch (error) {
      state = AsyncData(state.value!.copyWith(offline: true));
      AppLog.w('auth', 'server probe failed: ${error.code ?? '-'}');
    }
  }

  /// 退出登录（AUTH-10）：撤销远端 + 清理本地；失败也继续清理。
  Future<void> logout() async {
    final current = state.value;
    final profile = current?.profile;
    final serverId = profile?.id;
    try {
      if (_api != null) await _api!.revokeToken();
    } on Object catch (error) {
      AppLog.w('auth', 'revoke failed (ignored): $error');
    }
    if (serverId != null) {
      await _clearToken(profile!);
    }
    await _deleteGatewayAlias(current);
    try {
      await ref.read(pushServiceProvider).clearAlias();
    } on Object catch (error) {
      AppLog.w('push', 'clear alias failed (ignored): $error');
    }
    // H-6：登出同样清缓存、日志与导出文件（与「删除本地数据」一致）。
    await ref.read(appDatabaseProvider).wipeAllCache();
    try {
      await ref.read(secureStoreProvider).clear();
      await ref.read(logEraserProvider)();
      await ref.read(exportEraserProvider)();
    } on Object catch (error) {
      AppLog.w('auth', 'logout cleanup partial', code: '$error');
    }
    ref.read(socketClientProvider).disconnect();
    state = AsyncData(
      SessionState(phase: SessionPhase.anonymous, profile: profile),
    );
  }

  /// 登出时撤销推送网关别名（docs/09 §3.4 防串号）。
  ///
  /// 必须在 `secure.clear()` 之前调用（盐值还在）；
  /// 旧 Token 此刻可能已撤销，网关按注册时的映射删除，best-effort。
  Future<void> _deleteGatewayAlias(SessionState? session) async {
    final userId = session?.user?.id;
    final serverId = session?.profile?.id;
    if (userId == null || serverId == null) return;
    try {
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

  /// 401 统一入口。
  Future<void> expireSession() async {
    final profile = state.value?.profile;
    if (profile?.id != null) await _clearToken(profile!);
    _api = null;
    state = AsyncData(
      state.value?.copyWith(
            phase: SessionPhase.anonymous,
            clearToken: true,
            clearUser: true,
            apiClient: null,
          ) ??
          SessionState(phase: SessionPhase.anonymous, profile: profile),
    );
  }

  Future<void> _clearToken(ServerProfile profile) async {
    final id = profile.id;
    if (id == null) return;
    await ref.read(secureStoreProvider).delete(SecureKeys.token(id));
    await ref.read(secureStoreProvider).delete(SecureKeys.password(id));
    _api = null;
  }

  /// 登录后注册推送别名（CN-04；Noop 网关时为空操作）。
  Future<void> _registerPushAlias(Account user) async {
    // 钩子由 push 层提供（push_service.dart），避免循环依赖。
    // 会话 Token 必须带上：网关靠它反查 userId（H-2）。
    await ref.read(pushSessionHookProvider)(
      user.id,
      state.value?.profile?.id,
      state.value?.token,
    );
  }
}

/// 会话完成后的推送注册钩子：定义在 push 层（core/push/push_service.dart），
/// 这里只导入使用，依赖方向 session → push 单向。
final sessionControllerProvider =
    AsyncNotifierProvider<SessionController, SessionState>(
  SessionController.new,
);

/// OIDC 回跳的暂存项（冷启动深链先于会话恢复完成时）。
class _PendingOpenId {
  const _PendingOpenId(this.code, this.completer);

  final String code;
  final Completer<bool> completer;
}

/// SocketClient 单例（全局单连接，docs/03 §6.2）。
final socketClientProvider = Provider<SocketClient>((ref) {
  final socket = SocketClient();
  ref.onDispose(socket.dispose);
  return socket;
});
