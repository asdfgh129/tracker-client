import 'dart:convert';

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
  late final Dio dio;

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

  // ---- 会话 ----

  /// 密码登录：成功返回 User（docs/04 §2.1）。
  Future<Account> login(String email, String password) async {
    // 重置 Cookie，避免上一个账号的会话干扰。
    _cookieJar = CookieJar();
    dio = _buildDio();
    final response = await dio.post<String>(
      _sessionPath,
      data: 'email=${Uri.encodeQueryComponent(email)}'
          '&password=${Uri.encodeQueryComponent(password)}',
      options: Options(
        contentType: 'application/x-www-form-urlencoded',
        headers: {'Accept': 'application/json'},
      ),
    );
    if (response.statusCode != 200) throw _mapError(response);
    return Account.fromJson(_decodeMap(response.data));
  }

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
