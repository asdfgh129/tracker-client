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

/// 会话状态（docs/03 §15.1）。
class SessionState {
  const SessionState({
    required this.phase,
    this.token,
    this.user,
    this.profile,
    this.serverVersion,
    this.offline = false,
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

  @override
  Future<SessionState> build() async {
    final serverState = ref.watch(serverProfileControllerProvider).value;
    final profile = serverState?.activeProfile;
    final prefs = ref.watch(prefsProvider);

    // 恢复：有档案 + 有 Token → 校验；失败降级只读（offline）。
    final serverId = profile?.id;
    if (profile == null || serverId == null) {
      return SessionState(phase: SessionPhase.anonymous, profile: profile);
    }

    final secure = ref.read(secureStoreProvider);
    final token = await secure.read(SecureKeys.token(serverId));
    if (token == null || token.isEmpty) {
      return SessionState(phase: SessionPhase.anonymous, profile: profile);
    }

    // 生物识别锁在 UI 层拦截进入主界面；会话本身仍是已认证。
    final user = await _restoreUser(profile, token);
    _api = _createApi(profile, token);
    final biometricEnabled = prefs.getBool(SecureKeys.biometricEnabled) ?? false;
    final unlocked = !biometricEnabled;
    if (user == null) {
      // 离线降级：缓存中已认证过（有 Token 即视为会话存在）。
      final offlineApi = _createApi(profile, token);
      _api = offlineApi;
      return SessionState(
        phase: SessionPhase.authenticated,
        token: token,
        profile: profile,
        offline: true,
        unlocked: unlocked,
        biometricEnabled: biometricEnabled,
        apiClient: offlineApi,
      );
    }
    final restoredApi = _createApi(profile, token);
    _api = restoredApi;
    return SessionState(
      phase: SessionPhase.authenticated,
      token: token,
      user: user,
      profile: profile,
      offline: false,
      unlocked: unlocked,
      biometricEnabled: biometricEnabled,
      serverVersion: _cachedVersion(prefs),
      apiClient: restoredApi,
    );
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

  Future<Account?> _restoreUser(ServerProfile profile, String token) async {
    try {
      final api = _createApi(profile, token);
      final user = await api.currentUser();
      AppLog.i('auth', 'session restored');
      return user;
    } on AppFailure catch (error) {
      // 网络错误：离线降级；401：清会话。
      AppLog.w('auth', 'restore failed: ${error.code ?? 'no-code'}');
      if (error is UnauthorizedFailure) {
        await _clearToken(profile);
      }
      return null;
    } on Object catch (error) {
      AppLog.w('auth', 'restore crashed: $error');
      return null;
    }
  }

  /// 密码登录（AUTH-04/05）。
  Future<void> loginWithPassword({
    required String email,
    required String password,
    bool rememberPassword = false,
  }) async {
    final profile = state.value?.profile;
    if (profile == null || profile.id == null) {
      throw const ConfigFailure('请先配置服务器');
    }
    try {
      final api = _createApi(profile, null);
      final user = await api.login(email, password);
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

  /// 探测服务器版本（进主界面后刷新，AUTH-11）。
  Future<void> refreshServerInfo() async {
    final profile = state.value?.profile;
    if (profile == null) return;
    try {
      final server = await apiFor(state.value!).getServer();
      final version = server['version']?.toString();
      final prefs = ref.read(prefsProvider);
      if (version != null) await prefs.setString('app.serverVersion', version);
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
    await ref.read(pushSessionHookProvider)(user.id, state.value?.profile?.id);
  }
}

/// 会话完成后的推送注册钩子：定义在 push 层（core/push/push_service.dart），
/// 这里只导入使用，依赖方向 session → push 单向。
final sessionControllerProvider =
    AsyncNotifierProvider<SessionController, SessionState>(
  SessionController.new,
);

/// SocketClient 单例（全局单连接，docs/03 §6.2）。
final socketClientProvider = Provider<SocketClient>((ref) {
  final socket = SocketClient();
  ref.onDispose(socket.dispose);
  return socket;
});
