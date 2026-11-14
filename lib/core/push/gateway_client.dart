import 'package:dio/dio.dart';

import '../observability/logger.dart';

/// 自建推送网关客户端（CN-04，契约见 server/README.md §2.2）。
///
/// App 登录后注册别名；网关按别名经极光投递。
/// 未配置网关地址（`--dart-define=PUSH_GATEWAY_URL`）时全部调用静默跳过。
///
/// 安全说明（C-1/H-2）：客户端**不持有**网关管理令牌。
/// 网关通过 App 携带的 Traccar 会话 Token 反查 userId 并签发别名的随机盐，
/// 因此别名不可枚举、且只能注册到自己的账号下。
class PushGatewayClient {
  PushGatewayClient({required String baseUrl, String? sessionToken})
      : _dio = Dio(
          BaseOptions(
            baseUrl: baseUrl,
            connectTimeout: const Duration(seconds: 5),
            receiveTimeout: const Duration(seconds: 10),
          ),
        ) {
    if (sessionToken != null && sessionToken.isNotEmpty) {
      _dio.options.headers['Authorization'] = 'Bearer $sessionToken';
    }
  }

  final Dio _dio;

  /// 申请别名随机盐（C-2）。
  ///
  /// 网关用 [sessionToken] 向 Traccar 校验身份后，返回
  /// `{salt, alias}`；客户端只负责保存与使用，不自行编造身份。
  Future<String?> requestAliasSalt({
    required int userId,
    required int serverId,
  }) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/v1/alias-salt',
        data: {'serverId': serverId},
      );
      final data = response.data;
      final salt = data?['salt']?.toString();
      if (salt == null || salt.length < 16) return null;
      return salt;
    } on DioException catch (error) {
      AppLog.w('push', 'alias salt request failed: ${error.response?.statusCode}');
      return null;
    }
  }

  /// 注册/更新别名。App 会话 Token 用于鉴权（网关校验后映射）。
  ///
  /// 返回网关为该别名签发的**指令签名密钥**（H-4，每别名独立）；
  /// null = 注册失败。密钥经 HTTPS 下发，客户端存 Secure Storage，
  /// 用于校验下行远程指令的 HMAC 签名。
  Future<String?> registerAlias({
    required String alias,
    required String platform,
    String? vendor,
    String? appVersion,
    String? deviceModel,
  }) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/v1/aliases',
        data: {
          'alias': alias,
          'platform': platform,
          if (vendor != null) 'vendor': vendor,
          if (appVersion != null) 'appVersion': appVersion,
          if (deviceModel != null) 'deviceModel': deviceModel,
        },
      );
      final ok = response.statusCode != null &&
          response.statusCode! >= 200 &&
          response.statusCode! < 300;
      if (!ok) return null;
      final secret = response.data?['commandSecret']?.toString();
      return (secret != null && secret.length >= 32) ? secret : null;
    } on DioException catch (error) {
      AppLog.w('push', 'alias register failed: ${error.response?.statusCode}');
      return null;
    }
  }

  /// 退出登录时删除别名（避免消息串号，docs/09 §3.4）。
  Future<void> deleteAlias(String alias) async {
    try {
      await _dio.delete<void>('/v1/aliases/$alias');
    } on DioException catch (error) {
      AppLog.w('push', 'alias delete failed: ${error.response?.statusCode}');
    }
  }
}
