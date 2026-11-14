/// 统一错误模型（docs/03 §11）。
///
/// UI 只展示 `userMessage`；详细错误进日志与崩溃上报（附带 code，不含 token/位置）。
sealed class AppFailure implements Exception {
  const AppFailure(this.message, {this.code});

  final String message;
  final String? code;

  String get userMessage => message;

  @override
  String toString() => '$runtimeType(code: $code): $message';
}

/// 网络不可达 / DNS / 连接失败。
class NetworkFailure extends AppFailure {
  const NetworkFailure({String? message, super.code})
      : super(message ?? '网络不可用，请检查网络连接');
}

/// 请求超时。
class TimeoutFailure extends AppFailure {
  const TimeoutFailure({String? message, super.code})
      : super(message ?? '连接超时，请稍后重试');
}

/// 401：会话失效。
class UnauthorizedFailure extends AppFailure {
  const UnauthorizedFailure({String message = '登录已过期，请重新登录', String? code})
      : super(message, code: code);
}

/// 403：无权限。
class ForbiddenFailure extends AppFailure {
  const ForbiddenFailure({String message = '没有执行此操作的权限', String? code})
      : super(message, code: code);
}

/// 404：资源不存在。
class NotFoundFailure extends AppFailure {
  const NotFoundFailure({String message = '资源不存在', String? code})
      : super(message, code: code);
}

/// 429：限流。
class RateLimitedFailure extends AppFailure {
  const RateLimitedFailure({String message = '请求过于频繁，请稍后重试', String? code})
      : super(message, code: code);
}

/// 5xx：服务端错误。
class ServerFailure extends AppFailure {
  const ServerFailure({String message = '服务器错误，请稍后重试', String? code})
      : super(message, code: code);
}

/// 4xx：业务参数错误（服务端 message 优先）。
class ValidationFailure extends AppFailure {
  const ValidationFailure(super.message, {super.code});
}

/// 跟踪引擎错误。
class TrackingFailure extends AppFailure {
  const TrackingFailure(super.message, {super.code});
}

/// 权限缺失 / 被拒。
class PermissionFailure extends AppFailure {
  const PermissionFailure(super.message, {super.code});
}

/// 配置 / 输入错误（如地址格式不合法）。
class ConfigFailure extends AppFailure {
  const ConfigFailure(super.message, {super.code});
}

/// 5056 消息通道错误：应答超时或连接关闭。
///
/// 应答超时意味着**请求已发出、结果未知**——调用方不得把它当作
/// 服务端拒绝或成功处理（此前 `_call` 超时会伪造
/// `{success: false}` 应答，导致调用方误判）。
class MessagingFailure extends AppFailure {
  const MessagingFailure({String? message, super.code})
      : super(message ?? '消息通道无响应，请检查网络后重试');
}

/// 未知错误兜底。
class UnknownFailure extends AppFailure {
  const UnknownFailure(super.message, {super.code});
}
