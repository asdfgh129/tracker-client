import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import '../observability/logger.dart';
import 'push_gateway.dart';

/// FCM 后台消息处理。必须在 `main()` 之前通过
/// `FirebaseMessaging.onBackgroundMessage` 注册（见 `initialize`）。
@pragma('vm:entry-point')
Future<void> fcmBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  // 只做轻量工作：写入缓存 / 更新角标，不初始化 UI。
}

/// 海外与开发环境使用的 FCM 通道。
///
/// 中国大陆 Android 无 GMS，FCM 不可用，生产包请改用 [JpushPushGateway]。
class FcmPushGateway implements PushGateway {
  FcmPushGateway();

  final StreamController<PushMessage> _messages =
      StreamController<PushMessage>.broadcast();

  PushMessage? _initialMessage;
  bool _initialized = false;

  /// 当前订阅的 topic（最多一个；切换账号必须先退订旧 topic）。
  String? _currentTopic;
  StreamSubscription<RemoteMessage>? _onMessageSubscription;
  StreamSubscription<RemoteMessage>? _onOpenedSubscription;

  @override
  String get id => 'fcm';

  @override
  Stream<PushMessage> get messages => _messages.stream;

  @override
  Future<void> initialize({required String alias}) async {
    if (_initialized) {
      await updateAlias(alias);
      return;
    }

    // FCM 依赖 Firebase。若崩溃上报未初始化 Firebase（CRASH_REPORTER=none），
    // 这里补一次；缺少 google-services.json 时降级，不影响应用启动。
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp();
      }
    } catch (error) {
      AppLog.w('push', 'Firebase 初始化失败，FCM 推送不可用', code: '$error');
      return;
    }

    _initialized = true;

    FirebaseMessaging.onBackgroundMessage(fcmBackgroundHandler);

    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(alert: true, badge: true, sound: true);

    _onMessageSubscription = FirebaseMessaging.onMessage.listen(
      (message) => _messages.add(PushMessage.fromData(message.data)),
    );
    _onOpenedSubscription = FirebaseMessaging.onMessageOpenedApp.listen(
      (message) => _messages.add(PushMessage.fromData(message.data)),
    );

    final initial = await messaging.getInitialMessage();
    if (initial != null) {
      _initialMessage = PushMessage.fromData(initial.data);
    }

    await updateAlias(alias);
  }

  @override
  Future<void> updateAlias(String alias) async {
    if (!_initialized) return;
    final topic = topicFor(alias);
    if (_currentTopic == topic) return;
    final previous = _currentTopic;
    _currentTopic = topic;
    if (previous != null) {
      // 登出/换号后必须退订旧 topic，否则仍会收到上一账号的事件推送。
      try {
        await FirebaseMessaging.instance.unsubscribeFromTopic(previous);
      } on Object catch (error) {
        AppLog.w('push', 'unsubscribe $previous failed', code: '$error');
      }
    }
    await FirebaseMessaging.instance.subscribeToTopic(topic);
  }

  @override
  Future<void> clearAlias() async {
    final topic = _currentTopic;
    _currentTopic = null;
    if (topic == null) return;
    try {
      await FirebaseMessaging.instance.unsubscribeFromTopic(topic);
    } on Object catch (error) {
      AppLog.w('push', 'clearAlias failed', code: '$error');
    }
  }

  @override
  Future<PushMessage?> takeInitialMessage() async {
    final message = _initialMessage;
    _initialMessage = null;
    return message;
  }

  @override
  Future<void> dispose() async {
    await clearAlias();
    await _onMessageSubscription?.cancel();
    await _onOpenedSubscription?.cancel();
    await _messages.close();
  }

  /// FCM Topic 只允许 `[a-zA-Z0-9-_.~%]`，因此把 alias 里的 `@` 等替换掉。
  static String topicFor(String alias) =>
      'u_${alias.replaceAll(RegExp('[^A-Za-z0-9_]'), '_')}';
}
