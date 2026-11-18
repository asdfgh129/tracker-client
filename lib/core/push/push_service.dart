import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../config/build_config.dart';
import '../observability/logger.dart';
import '../storage/secure_store.dart';
import 'fcm_push_gateway.dart';
import 'gateway_client.dart';
import 'jpush_push_gateway.dart';
import 'push_gateway.dart';

/// 按构建配置选择推送通道。
///
/// 中国大陆生产包：`--dart-define=PUSH_PROVIDER=jpush`
/// 海外 / 开发包：`--dart-define=PUSH_PROVIDER=fcm`
final pushGatewayProvider = Provider<PushGateway>((ref) {
  final gateway = switch (BuildConfig.pushProvider) {
    'fcm' => FcmPushGateway(),
    'jpush' => JpushPushGateway(),
    _ => NoopPushGateway(),
  };
  ref.onDispose(gateway.dispose);
  return gateway;
});

final pushServiceProvider = Provider<PushService>(
  (ref) => PushService(ref.watch(pushGatewayProvider)),
);

/// 登录后的推送注册钩子（session 层调用；网关未配置时自动跳过）。
///
/// [sessionToken] 用于网关反查身份（H-2）——此前遗漏该参数导致
/// `/v1/alias-salt` 恒 401，别名注册从未成功过（已修复）。
///
/// 中国大陆链路：`POST /v1/aliases`（网关）+ `setAlias`（极光 SDK）。
/// 海外链路：alias 映射为 FCM topic 订阅（见 FcmPushGateway.updateAlias）。
final pushSessionHookProvider =
    Provider<Future<void> Function(int userId, int? serverId, String? sessionToken)>(
        (ref) {
  return (userId, serverId, sessionToken) async {
    final sid = serverId ?? 0;
    final gatewayUrl = BuildConfig.pushGatewayUrl;
    if (gatewayUrl.isEmpty) {
      AppLog.i('push', 'gateway 未配置，跳过别名注册（仅应用内事件）');
      return;
    }

    final secure = ref.read(secureStoreProvider);
    final saltKey = aliasSaltKey(sid);

    // C-2：别名必须含服务端签发的随机盐。已有则复用，没有则向网关申请。
    String? salt = await secure.read(saltKey);
    final client = PushGatewayClient(
      baseUrl: gatewayUrl,
      sessionToken: sessionToken,
    );

    if (salt == null || salt.length < 16) {
      salt = await client.requestAliasSalt(userId: userId, serverId: sid);
      if (salt == null) {
        AppLog.w('push', '未能取得别名盐值，跳过别名注册（避免可猜别名）');
        return;
      }
      await secure.write(saltKey, salt);
    }

    final alias = PushService.aliasFor(
      userId: userId,
      serverId: sid,
      salt: salt,
    );
    if (alias == null) {
      AppLog.w('push', 'alias 构造失败（盐值不足），跳过注册');
      return;
    }

    final info = await PackageInfo.fromPlatform();
    final platform =
        defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';
    // 契约里的 vendor/deviceModel 供网关侧诊断（按厂商通道排障），
    // 获取失败不阻塞注册（对齐审计 P3-7：此前两字段恒缺）。
    String? vendor;
    String? deviceModel;
    try {
      final deviceInfo = DeviceInfoPlugin();
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        final ios = await deviceInfo.iosInfo;
        vendor = 'apple';
        deviceModel = ios.model;
      } else if (defaultTargetPlatform == TargetPlatform.android) {
        final android = await deviceInfo.androidInfo;
        vendor = android.manufacturer;
        deviceModel = android.model;
      }
    } on Object catch (error) {
      AppLog.w('push', 'device info unavailable: $error');
    }
    final commandSecret = await client.registerAlias(
      alias: alias,
      platform: platform,
      vendor: vendor,
      appVersion: info.version,
      deviceModel: deviceModel,
    );
    AppLog.i(
      'push',
      'gateway alias ${commandSecret != null ? 'registered' : 'register failed'}',
    );
    if (commandSecret != null) {
      // H-4：持久化每别名指令签名密钥，供 CommandCenter 验签。
      await secure.write(SecureKeys.commandSecret(sid), commandSecret);
    }

    // 网关会在服务端把 alias 绑定到已认证用户，客户端不再自行拼接身份。
    await ref.read(pushServiceProvider).initializeAlias(alias);
  };
});

/// 别名盐值的 Secure Storage 键（登出撤销时需读取）。
String aliasSaltKey(int serverId) => 'push.aliasSalt.$serverId';

/// 登出 / 切换服务器时撤销网关别名（best-effort，docs/09 §3.4 防串号）。
///
/// **必须在清除 Secure Storage 之前调用**（盐值尚在才能算出完整别名）。
/// 网关未配置时静默跳过；网络失败只记日志，不阻塞登出流程。
Future<void> deleteGatewayAliasFor({
  required int userId,
  required int serverId,
  required String? salt,
  String? sessionToken,
}) async {
  final gatewayUrl = BuildConfig.pushGatewayUrl;
  if (gatewayUrl.isEmpty) return;
  final alias = PushService.aliasFor(
    userId: userId,
    serverId: serverId,
    salt: salt,
  );
  if (alias == null) return;
  final client = PushGatewayClient(
    baseUrl: gatewayUrl,
    sessionToken: sessionToken,
  );
  await client.deleteAlias(alias);
}

/// 推送服务门面：把 alias 规则、注册时机、消息路由集中在一处。
///
/// 推送链路（中国大陆）：
/// ```
/// Traccar 事件
///   -> NotificatorWebhook（服务端插件）
///   -> 自建推送网关（鉴权 / 去重 / 模板 / 限流）
///   -> JPush REST（按 alias）
///   -> 厂商通道 -> App
/// ```
class PushService {
  const PushService(this._gateway);

  final PushGateway _gateway;

  /// alias 规范：`u{userId}@{serverId}.{salt}`。
  ///
  /// - 带 serverId：支持一个用户连接多个 Traccar 服务器时不串消息；
  /// - 带 salt（C-2）：**必须**由服务端签发的不可猜测随机值，
  ///   否则 `u5@1` 这种可枚举别名/主题会让任何人订阅到他人的事件推送
  ///   （行踪信息的旁路泄露）。
  ///
  /// salt 由推送网关在注册时返回并落 Secure Storage；未取到时返回 null，
  /// 调用方应跳过注册而不是退化为可猜别名。
  static String? aliasFor({
    required int userId,
    required int serverId,
    required String? salt,
  }) {
    if (salt == null || salt.length < 16) return null;
    return 'u$userId@$serverId.$salt';
  }

  /// 是否已满足安全别名要求（诊断页可见）。
  static bool isAliasSecure(String? alias) {
    if (alias == null) return false;
    final parts = alias.split('.');
    return parts.length == 2 && parts[1].length >= 16;
  }

  /// 用已签发的安全别名初始化通道（C-2）。
  Future<void> initializeAlias(String alias) => _gateway.initialize(alias: alias);

  Future<void> updateAliasString(String alias) => _gateway.updateAlias(alias);

  /// 登出 / 换账号：解除当前推送别名订阅。
  Future<void> clearAlias() => _gateway.clearAlias();

  Stream<PushMessage> get messages => _gateway.messages;

  /// 冷启动点击通知：登录完成后再调用，避免路由竞态。
  Future<PushMessage?> takeInitialMessage() => _gateway.takeInitialMessage();
}
