import 'dart:convert';
import 'dart:io' show HttpDate, HttpHeaders;

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

import '../../domain/entities/models.dart';
import '../../domain/failures.dart';
import '../observability/logger.dart';
import 'certificate_policy.dart';
import 'interceptors.dart';
import 'server_profile.dart';

/// Traccar 6.x REST 客户端（docs/04 接口清单）。
///
/// 认证流程：
/// 1. `POST /api/session`（form：email/password）→ Set-Cookie；
/// 2. `POST /api/session/token` → 纯文本长期 Token；
/// 3. 之后全部 REST 用 `Authorization: Bearer <token>`。
class TraccarApi {
  TraccarApi({
    required this.profile,
    String? token,
    this.onUnauthorized,
    CookieJar? cookieJar,
  })  : _token = token,
        _cookieJar = cookieJar ?? CookieJar() {
    dio = _buildDio();
  }

  final ServerProfile profile;

  /// 401 时回调（清会话回登录页，docs/01 §3.2）。
  final void Function()? onUnauthorized;

  String? _token;
  CookieJar _cookieJar;

  // 不能声明为 `late final`：登录前需要重建（换 CookieJar）并二次赋值，
  // 否则会抛 `LateInitializationError`，导致密码登录 100% 失败。
  late Dio dio;

  /// 会话 Cookie 只在登录换取 Token 阶段使用。
  static const String _sessionPath = '/api/session';

  String? get token => _token;

  void updateToken(String? token) => _token = token;

  Dio _buildDio() {
    final options = BaseOptions(
      baseUrl: profile.apiBaseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
      headers: {'Accept': 'application/json'},
      // Traccar 的 /api/session/token 返回纯文本。
      responseType: ResponseType.plain,
      validateStatus: (code) => code != null && code < 500,
    );
    final client = Dio(options);
    final retry = RetryInterceptor();
    client.interceptors.addAll([
      CookieManager(_cookieJar),
      AuthInterceptor(
        tokenProvider: () => _token,
        onUnauthorized: onUnauthorized,
      ),
      retry,
      const ErrorMappingInterceptor(),
      const RedactedLogInterceptor(),
    ]);
    retry.attach(client);
    applyCertificatePolicy(client, profile.allowSelfSigned);
    return client;
  }

  // ---- 服务器与能力探测（AUTH-11）----

  /// `GET /api/server`，无需认证。返回原始 JSON。
  Future<Map<String, dynamic>> getServer() async {
    final data = await _getJson('/api/server');
    if (data is! Map<String, dynamic>) {
      throw const ValidationFailure('未检测到 Traccar API');
    }
    return data;
  }

  /// 服务器与本机的时钟偏差（诊断页）：
  /// 解析响应 `Date` 头，失败（离线 / 无该头）返回 null。
  Future<Duration?> serverClockSkew() async {
    try {
      final response = await dio.get<dynamic>('/api/server');
      final header = response.headers.value(HttpHeaders.dateHeader);
      if (header == null) return null;
      final server = HttpDate.parse(header).toUtc();
      return server.difference(DateTime.now().toUtc());
    } on Object {
      return null;
    }
  }

  // ---- 会话 ----

  /// 密码登录：成功返回 User（docs/04 §2.1）。
  ///
  /// 服务端账号开启 TOTP 时首次请求返回 401 + `WWW-Authenticate: TOTP`，
  /// 抛 [TotpRequiredFailure]；调用方收集验证码后携带 [code] 重试
  /// （服务端 form `code` 字段，SessionResource）。
  Future<Account> login(String email, String password, {String? code}) async {
    // 重置 Cookie，避免上一个账号的会话干扰（会重建 dio，故不能是 late final）。
    _cookieJar = CookieJar();
    dio = _buildDio();
    final response = await dio.post<String>(
      _sessionPath,
      data: 'email=${Uri.encodeQueryComponent(email)}'
          '&password=${Uri.encodeQueryComponent(password)}'
          '${(code != null && code.isNotEmpty) ? '&code=${Uri.encodeQueryComponent(code)}' : ''}',
      options: Options(
        contentType: 'application/x-www-form-urlencoded',
        headers: {'Accept': 'application/json'},
      ),
    );
    if (response.statusCode == 401 && _isTotpChallenge(response)) {
      throw const TotpRequiredFailure(code: 'totp_required');
    }
    if (response.statusCode != 200) throw _mapError(response);
    return Account.fromJson(_decodeMap(response.data));
  }

  /// 服务端 TOTP 二次验证质询（`WWW-Authenticate: TOTP`）。
  static bool _isTotpChallenge(Response<String> response) =>
      response.headers.value('www-authenticate')?.toUpperCase().contains('TOTP') ??
      false;

  /// 用会话 Cookie 换长期 Token（纯文本）。
  Future<String> exchangeToken() async {
    final response = await dio.post<String>('/api/session/token');
    if (response.statusCode != 200) throw _mapError(response);
    final token = (response.data ?? '').trim().replaceAll('"', '');
    if (token.isEmpty) {
      throw const ValidationFailure('服务器未返回会话 Token');
    }
    _token = token;
    return token;
  }

  /// OIDC 一次性 code 换长期 Token（TrackerOne 0.5.0，docs/04 §2.3）。
  ///
  /// code 来自 `trackerone://openid/callback` 深链，由服务端在完成
  /// IdP 校验后签发（单次消费、5 分钟 TTL）；无需会话 Cookie（@PermitAll）。
  Future<String> exchangeOpenIdCode(String code) async {
    final response = await dio.post<String>(
      '/api/session/openid/mobile',
      data: 'code=${Uri.encodeQueryComponent(code)}',
      options: Options(contentType: 'application/x-www-form-urlencoded'),
    );
    if (response.statusCode != 200) throw _mapError(response);
    final token = (response.data ?? '').trim().replaceAll('"', '');
    if (token.isEmpty) {
      throw const ValidationFailure('服务器未返回会话 Token');
    }
    _token = token;
    return token;
  }

  /// Token 直接登录 / 校验（docs/04 §2.2）。
  Future<Account> validateToken(String token) async {
    _token = token;
    final response = await dio.get<String>(_sessionPath);
    if (response.statusCode != 200) {
      _token = null;
      throw _mapError(response);
    }
    return Account.fromJson(_decodeMap(response.data));
  }

  /// 当前用户。
  Future<Account> currentUser() async {
    final response = await dio.get<String>(_sessionPath);
    if (response.statusCode != 200) throw _mapError(response);
    return Account.fromJson(_decodeMap(response.data));
  }

  /// 退出登录并撤销 Token（AUTH-10：失败也清理本地）。
  Future<void> revokeToken() async {
    final token = _token;
    if (token == null) return;
    try {
      await dio.post<String>(
        '/api/session/token/revoke',
        data: 'token=${Uri.encodeQueryComponent(token)}',
        options: Options(contentType: 'application/x-www-form-urlencoded'),
      );
    } on Object catch (error) {
      AppLog.w('api', 'token revoke failed (ignored): $error');
    }
  }

  /// 更新用户 attributes（FCM 通知 Token 注册，仅海外链路）。
  Future<Account> updateUser(int id, Map<String, dynamic> user) async {
    final response = await dio.put<String>('/api/users/$id', data: user);
    if (response.statusCode != 200) throw _mapError(response);
    return Account.fromJson(_decodeMap(response.data));
  }

  // ---- 设备 ----

  /// `GET /api/devices`（docs/04 §3.2）。
  Future<List<Device>> getDevices({String? uniqueId, String? keyword}) async {
    final response = await dio.get<String>(
      '/api/devices',
      queryParameters: {
        if (uniqueId != null) 'uniqueId': uniqueId,
        if (keyword != null && keyword.isNotEmpty) 'keyword': keyword,
      },
    );
    if (response.statusCode != 200) throw _mapError(response);
    return _decodeList(response.data)
        .map((item) => Device.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  /// 创建设备（TRK-02 本机绑定；403 → 联系管理员）。
  Future<Device> createDevice({
    required String name,
    required String uniqueId,
    String category = 'phone',
    Map<String, dynamic> attributes = const {},
  }) async {
    final response = await dio.post<String>(
      '/api/devices',
      data: <String, dynamic>{
        'name': name,
        'uniqueId': uniqueId,
        'category': category,
        'attributes': attributes,
      },
    );
    if (response.statusCode != 200) throw _mapError(response);
    return Device.fromJson(_decodeMap(response.data));
  }

  /// 更新设备（含 attributes，如 FCM notificationTokens）。
  Future<Device> updateDevice(Map<String, dynamic> device) async {
    final response = await dio.put<String>(
      '/api/devices/${device['id']}',
      data: device,
    );
    if (response.statusCode != 200) throw _mapError(response);
    return Device.fromJson(_decodeMap(response.data));
  }

  // ---- 位置 ----

  /// 最新位置快照（无参）或时间范围（docs/04 §3.3）。
  Future<List<Position>> getPositions({
    int? deviceId,
    DateTime? from,
    DateTime? to,
  }) async {
    final response = await dio.get<String>(
      '/api/positions',
      queryParameters: {
        if (deviceId != null) 'deviceId': deviceId,
        if (from != null) 'from': _iso(from),
        if (to != null) 'to': _iso(to),
      },
    );
    if (response.statusCode != 200) throw _mapError(response);
    return _decodeList(response.data)
        .map((item) => Position.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  // ---- 事件 ----

  /// 没有列表接口：历史事件走 `/api/reports/events`（docs/04 §3.4）。
  Future<List<DeviceEvent>> getEventsHistory({
    required int deviceId,
    required DateTime from,
    required DateTime to,
  }) async {
    final response = await dio.get<String>(
      '/api/reports/events',
      queryParameters: {
        'deviceId': deviceId,
        'from': _iso(from),
        'to': _iso(to),
        'type': '',
      },
    );
    if (response.statusCode != 200) throw _mapError(response);
    return _decodeList(response.data)
        .map((item) => DeviceEvent.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  /// 全量历史事件（不区分设备，一次请求覆盖用户可见的全部设备）。
  ///
  /// `/api/events?from&to`（Traccar ≥4.8 支持 from/to）。
  /// 用于事件补拉兜底：替代逐设备 `/api/reports/events` 循环，
  /// 避免设备多时补拉不全（此前只取前 10 个设备）。
  Future<List<DeviceEvent>> getAllEvents({
    required DateTime from,
    required DateTime to,
  }) async {
    final response = await dio.get<String>(
      '/api/events',
      queryParameters: {
        'from': _iso(from),
        'to': _iso(to),
      },
    );
    if (response.statusCode != 200) throw _mapError(response);
    return _decodeList(response.data)
        .map((item) => DeviceEvent.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<DeviceEvent?> getEvent(int id) async {
    final response = await dio.get<String>('/api/events/$id');
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) throw _mapError(response);
    return DeviceEvent.fromJson(_decodeMap(response.data));
  }

  // ---- 指令（DEV-04/05）----

  /// 已保存指令。
  Future<List<Map<String, dynamic>>> getCommands({int? deviceId}) async {
    final response = await dio.get<String>(
      '/api/commands',
      queryParameters: {if (deviceId != null) 'deviceId': deviceId},
    );
    if (response.statusCode != 200) throw _mapError(response);
    return _decodeList(response.data)
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
  }

  /// 该设备支持的指令类型（按协议过滤，docs/04 §3.5）。
  Future<List<String>> getCommandTypes(int deviceId) async {
    final response = await dio.get<String>(
      '/api/commands/send',
      queryParameters: {'deviceId': deviceId},
    );
    if (response.statusCode != 200) throw _mapError(response);
    final list = _decodeList(response.data);
    return [
      for (final item in list)
        if (item is Map<String, dynamic> && item['type'] is String)
          item['type'] as String,
    ];
  }

  /// 发送指令。200=已发送，202=已排队（docs/04 §3.5）。
  Future<CommandResult> sendCommand({
    required int deviceId,
    required String type,
    Map<String, dynamic> attributes = const {},
  }) async {
    final response = await dio.post<String>(
      '/api/commands/send',
      data: <String, dynamic>{
        'deviceId': deviceId,
        'type': type,
        'attributes': attributes,
      },
    );
    final status = response.statusCode ?? 0;
    if (status != 200 && status != 202) throw _mapError(response);
    return CommandResult(queued: status == 202, raw: _decodeMap(response.data));
  }

  // ---- 通知规则（离线推送开关；管理员创建的用户需在此自行开启）----

  /// 当前用户的通知规则。
  Future<List<Map<String, dynamic>>> getNotifications() async {
    final response = await dio.get<String>('/api/notifications');
    if (response.statusCode != 200) throw _mapError(response);
    return _decodeList(response.data)
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
  }

  /// 新建通知规则。notificators 建议 `web,webhook`：
  /// web = 在线 WebSocket 推送，webhook = 离线经推送网关 → 极光。
  Future<Map<String, dynamic>> createNotificationRule({
    required String type,
    required bool always,
    required String notificators,
  }) async {
    final response = await dio.post<String>(
      '/api/notifications',
      data: <String, dynamic>{
        'type': type,
        'always': always,
        'notificators': notificators,
      },
    );
    if (response.statusCode != 200) throw _mapError(response);
    return _decodeMap(response.data);
  }

  /// 删除通知规则。
  Future<void> deleteNotificationRule(int id) async {
    final response = await dio.delete<String>('/api/notifications/$id');
    final status = response.statusCode ?? 0;
    if (status != 200 && status != 204) throw _mapError(response);
  }

  // ---- 内部工具 ----

  static String _iso(DateTime time) =>
      time.toUtc().toIso8601String().replaceFirst(RegExp(r'\.\d+'), 'Z');

  Future<dynamic> _getJson(String path) async {
    final response = await dio.get<String>(path);
    if (response.statusCode != 200) throw _mapError(response);
    return _decode(response.data);
  }

  static dynamic _decode(String? body) {
    if (body == null || body.isEmpty) return const <String, dynamic>{};
    try {
      return jsonDecode(body);
    } on FormatException {
      throw const ValidationFailure('服务器响应不是合法 JSON');
    }
  }

  static Map<String, dynamic> _decodeMap(String? body) {
    final decoded = _decode(body);
    if (decoded is Map<String, dynamic>) return decoded;
    throw const ValidationFailure('服务器响应格式异常');
  }

  static List<dynamic> _decodeList(String? body) {
    final decoded = _decode(body);
    if (decoded is List<dynamic>) return decoded;
    throw const ValidationFailure('服务器响应格式异常');
  }

  static AppFailure _mapError(Response<String>? response) =>
      ErrorMappingInterceptor.mapDioException(
        DioException(
          requestOptions: RequestOptions(path: ''),
          response: response,
          type: DioExceptionType.badResponse,
        ),
      );
}

/// 自签名证书策略：仅当档案显式开启（docs/04 §10）。
///
/// 通过条件导入分离 IO 与非 IO 实现，避免在 Web/测试环境引用 dart:io。
void applyCertificatePolicy(Dio client, bool allow) =>
    certificatePolicyHook(client, allow);

/// 指令发送结果（DEV-05）。
class CommandResult {
  const CommandResult({required this.queued, this.raw = const {}});

  /// true = 已排队（设备离线），false = 已即时发送。
  final bool queued;
  final Map<String, dynamic> raw;
}

/// `GET /api/server` 响应字段提取。
///
/// Traccar 模型的 attributes 经 Jackson 序列化为**嵌套**对象
/// （`attributes.version`），顶层不存在该字段——此前直接读顶层
/// 恒为 null（诊断页版本一直显示 `-`）。保留顶层兜底以兼容拍平实现。
///
/// 注意：`openIdEnabled`/`openIdForce` 是 Server 模型的**顶层**布尔字段
/// （非 attributes），OIDC 登录按钮据此显隐。
class ServerInfo {
  static String? versionOf(Map<String, dynamic> server) =>
      _attr(server, 'version');

  /// 坐标系模式（tracker-server CN-1.2 起暴露；gcj02 时诊断页告警）。
  static String? coordinateSystemOf(Map<String, dynamic> server) =>
      _attr(server, 'coordinateSystem');

  /// 服务端是否启用 OIDC 企业登录（openIdProvider 已配置）。
  static bool? openIdEnabledOf(Map<String, dynamic> server) =>
      _topBool(server, 'openIdEnabled');

  /// 服务端是否强制 OIDC（`openid.force=true` 时密码登录被服务端拒绝）。
  static bool? openIdForceOf(Map<String, dynamic> server) =>
      _topBool(server, 'openIdForce');

  static String? _attr(Map<String, dynamic> server, String key) {
    final attributes = server['attributes'];
    final nested = attributes is Map<String, dynamic> ? attributes[key] : null;
    return (nested ?? server[key])?.toString();
  }

  static bool? _topBool(Map<String, dynamic> server, String key) {
    final value = server[key];
    return value is bool ? value : null;
  }
}
