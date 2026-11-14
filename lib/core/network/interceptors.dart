import 'dart:async';

import 'package:dio/dio.dart';

import '../../domain/failures.dart';
import '../observability/logger.dart';

/// 注入 `Authorization: Bearer`；401 时回调登出（docs/03 §6.1）。
///
/// 登录接口（`/api/session` POST）本身失败也会 401，不应触发登出循环，
/// 因此跳过。
class AuthInterceptor extends Interceptor {
  AuthInterceptor({required this.tokenProvider, this.onUnauthorized});

  final String? Function() tokenProvider;
  final void Function()? onUnauthorized;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final token = tokenProvider();
    if (token != null && token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final status = err.response?.statusCode;
    final path = err.requestOptions.path;
    final isLoginRequest =
        err.requestOptions.method == 'POST' && path.contains('/api/session');
    if (status == 401 && !isLoginRequest) {
      AppLog.w('api', '401 on $path, clearing session');
      onUnauthorized?.call();
    }
    super.onError(err, handler);
  }
}

/// 幂等请求重试（仅 GET，指数退避；POST/PUT/DELETE 不重试，docs/04 §8）。
class RetryInterceptor extends Interceptor {
  RetryInterceptor({
    this.maxRetries = 2,
    this.initialDelay = const Duration(milliseconds: 300),
  });

  final int maxRetries;
  final Duration initialDelay;

  Dio? _dio;

  /// 由 buildDio 在创建实例后回调绑定，重试时复用完整管线。
  void attach(Dio dio) => _dio = dio;

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final options = err.requestOptions;
    final retriableStatus = err.response?.statusCode;
    final isNetworkError = err.type == DioExceptionType.connectionError ||
        err.type == DioExceptionType.connectionTimeout;
    final isServerOrThrottle = retriableStatus != null &&
        (retriableStatus == 429 || retriableStatus >= 500);
    final retryable =
        options.method == 'GET' && (isNetworkError || isServerOrThrottle);
    final attempted = (options.extra['__retry_count__'] as int?) ?? 0;
    final dio = _dio;

    if (!retryable || attempted >= maxRetries || dio == null) {
      return handler.next(err);
    }

    options.extra['__retry_count__'] = attempted + 1;
    final delay = initialDelay * (1 << attempted);
    AppLog.d(
      'api',
      'retry ${options.method} ${options.path} (attempt=${attempted + 1})',
    );
    await Future<void>.delayed(delay);
    try {
      final response = await dio.fetch<dynamic>(options);
      return handler.resolve(response);
    } on DioException catch (error) {
      return handler.next(error);
    }
  }
}

/// 将 DioException 映射为 [AppFailure]，并提取服务端 message（docs/04 §8）。
class ErrorMappingInterceptor extends Interceptor {
  const ErrorMappingInterceptor();

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    handler.reject(err.copyWith(error: mapDioException(err)));
  }

  static AppFailure mapDioException(DioException err) {
    final response = err.response;
    final serverMessage = _serverMessage(response);

    switch (err.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return TimeoutFailure();
      case DioExceptionType.connectionError:
        return NetworkFailure();
      case DioExceptionType.badCertificate:
        return const NetworkFailure(message: '证书校验失败，请检查服务器证书');
      case DioExceptionType.cancel:
        return const UnknownFailure('请求已取消');
      case DioExceptionType.badResponse:
      case DioExceptionType.unknown:
      case DioExceptionType.transformTimeout:
        break;
    }

    final status = response?.statusCode ?? 0;
    switch (status) {
      case 400:
      case 422:
        return ValidationFailure(
          serverMessage ?? '请求参数错误',
          code: '$status',
        );
      case 401:
        return UnauthorizedFailure(
          message: serverMessage ?? '登录已过期，请重新登录',
          code: '401',
        );
      case 403:
        return ForbiddenFailure(
          message: serverMessage ?? '没有执行此操作的权限',
          code: '403',
        );
      case 404:
        return NotFoundFailure(
          message: serverMessage ?? '资源不存在',
          code: '404',
        );
      case 429:
        return RateLimitedFailure();
      case _ when status >= 500:
        return ServerFailure(code: '$status');
      case _ when status >= 400:
        return ValidationFailure(serverMessage ?? '请求失败', code: '$status');
      default:
        if (err.error is AppFailure) return err.error! as AppFailure;
        return UnknownFailure('请求失败：${err.message ?? err.type.name}');
    }
  }

  /// Traccar 错误响应是 `{"error": "..."} ` 或纯文本。
  static String? _serverMessage(Response<dynamic>? response) {
    if (response == null) return null;
    final data = response.data;
    if (data is Map<String, dynamic>) {
      final message = data['message'] ?? data['error'];
      final text = message?.toString();
      return text == null || text.isEmpty ? null : text;
    }
    if (data is String && data.isNotEmpty && data.length < 200) {
      return data;
    }
    return null;
  }
}

/// 脱敏请求日志（docs/03 §6.1：不记录 body 中的 token）。
class RedactedLogInterceptor extends Interceptor {
  const RedactedLogInterceptor();

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    AppLog.d('api', '${options.method} ${_sanitize(options)}');
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    AppLog.e(
      'api',
      '${err.requestOptions.method} ${_sanitize(err.requestOptions)} '
      '${err.response?.statusCode ?? '-'}',
      error: err.error,
    );
    handler.next(err);
  }

  static String _sanitize(RequestOptions options) {
    final uri = options.uri.toString();
    // WebSocket 查询参数中的 token 会出现在 URL；REST 也可能有 ?token=。
    return uri.replaceAll(
      RegExp(r'(token=)[^&]+', caseSensitive: false),
      r'token=<redacted>',
    );
  }
}
