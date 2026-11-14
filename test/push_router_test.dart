import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trackerone/core/push/push_gateway.dart';
import 'package:trackerone/core/push/push_router.dart';
import 'package:trackerone/core/push/push_service.dart';

/// 可注入消息流的假通道（NoopGateway 无法emit消息）。
class _FakePushGateway implements PushGateway {
  _FakePushGateway(this._controller);

  final StreamController<PushMessage> _controller;

  @override
  String get id => 'fake';

  @override
  Future<void> initialize({required String alias}) async {}

  @override
  Future<void> updateAlias(String alias) async {}

  @override
  Stream<PushMessage> get messages => _controller.stream;

  @override
  Future<PushMessage?> takeInitialMessage() async => null;

  // Sink 生命周期由测试 tearDown 统一管理（dispose 时不重复 close）。
  @override
  Future<void> dispose() async {}
}

void main() {
  late StreamController<PushMessage> controller;
  late ProviderContainer container;
  late PushRouter router;
  late List<PendingPushIntent> navigated;

  setUp(() {
    controller = StreamController<PushMessage>.broadcast();
    container = ProviderContainer(overrides: [
      pushServiceProvider
          .overrideWithValue(PushService(_FakePushGateway(controller))),
    ]);
    navigated = <PendingPushIntent>[];
    router = container.read(pushRouterProvider);
    router.onNavigate = navigated.add;
    router.start();
  });

  tearDown(() async {
    // ProviderContainer.dispose 为 void；Sink 在此统一关闭。
    container.dispose();
    await controller.close();
  });

  Future<void> pump() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  test('friendInvite push navigates to friends intent (session ready)', () async {
    router.setSessionReady(true);
    controller.add(PushMessage.fromData({
      'eventId': '',
      'type': 'friendInvite',
      'title': '好友申请',
    }));
    await pump();

    expect(navigated, hasLength(1));
    expect(navigated.single.friendInvite, isTrue);
    expect(navigated.single.eventId, isNull);
  });

  test('friendInvite push is cached before session ready, then released',
      () async {
    router.setSessionReady(false);
    controller.add(PushMessage.fromData({'type': 'friendInvite'}));
    await pump();
    expect(navigated, isEmpty);

    final released = router.consumePending();
    expect(released?.friendInvite, isTrue);
  });

  test('event push keeps eventId routing (no regression)', () async {
    router.setSessionReady(true);
    controller.add(PushMessage.fromData({'eventId': '555', 'deviceId': '7'}));
    await pump();

    expect(navigated, hasLength(1));
    expect(navigated.single.eventId, 555);
    expect(navigated.single.deviceId, 7);
    expect(navigated.single.friendInvite, isFalse);
  });

  test('push without eventId and without type stays ignored', () async {
    router.setSessionReady(true);
    controller.add(PushMessage.fromData({'deviceId': '7'}));
    await pump();

    expect(navigated, isEmpty);
  });
}
