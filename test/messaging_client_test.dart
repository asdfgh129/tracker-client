import 'package:flutter_test/flutter_test.dart';
import 'package:trackerone/core/network/messaging_client.dart';

void main() {
  test('auth success flips status to connected', () async {
    final client = MessagingClient();
    final statuses = <MessagingStatus>[];
    final sub = client.statusStream.listen(statuses.add);
    client.handleMessageForTest({
      'type': 'auth',
      'success': true,
      'device': {'id': 3, 'uniqueId': '12345678', 'name': 'self'},
    });
    await Future<void>.delayed(Duration.zero);
    expect(statuses, contains(MessagingStatus.connected));
    expect(client.status, MessagingStatus.connected);
    await sub.cancel();
  });

  test('password mismatch sets failed (no auto retry)', () async {
    final client = MessagingClient();
    final statuses = <MessagingStatus>[];
    final sub = client.statusStream.listen(statuses.add);
    client.handleMessageForTest({
      'type': 'error',
      'reason': 'password_mismatch',
    });
    await Future<void>.delayed(Duration.zero);
    expect(client.status, MessagingStatus.failed);
    expect(statuses, contains(MessagingStatus.failed));
    await sub.cancel();
  });

  test('device_disabled / invalid_unique_id are permanent failures', () async {
    // 对齐审计 P3-5：这两个 reason 重连无法解决，原先落入重连分支
    // 形成 ≤30s 间隔的重连循环，现与 password_mismatch 同样置为 failed。
    for (final reason in ['device_disabled', 'invalid_unique_id']) {
      final client = MessagingClient();
      final statuses = <MessagingStatus>[];
      final sub = client.statusStream.listen(statuses.add);
      client.handleMessageForTest({'type': 'error', 'reason': reason});
      await Future<void>.delayed(Duration.zero);
      expect(client.status, MessagingStatus.failed, reason: reason);
      expect(statuses, contains(MessagingStatus.failed), reason: reason);
      await sub.cancel();
    }
  });

  test('friends.invite emits with sender identity', () async {
    final client = MessagingClient();
    final invites = <FriendInvite>[];
    final sub = client.invitesStream.listen(invites.add);
    client.handleMessageForTest({
      'type': 'friends.invite',
      'from': {'id': 9, 'uniqueId': '87654321', 'name': 'Bob'},
    });
    await Future<void>.delayed(Duration.zero);
    expect(invites, hasLength(1));
    expect(invites.first.fromUniqueId, '87654321');
    expect(invites.first.fromDeviceId, 9);
    expect(invites.first.fromName, 'Bob');
    await sub.cancel();
  });

  test('friends.list reply parses friends and position snapshot', () async {
    final client = MessagingClient();
    final seen = <List<FriendEntry>>[];
    final sub = client.friendsStream.listen(seen.add);
    client.handleMessageForTest({
      'type': 'friends.list',
      'success': true,
      'friends': [
        {
          'id': 5,
          'uniqueId': '11111111',
          'name': 'Alice',
          'status': 'accepted',
          'online': true,
          'position': {'latitude': 32.06, 'longitude': 118.79},
          'lastTime': 1700000000,
        },
        {
          'id': 6,
          'uniqueId': '22222222',
          'status': 'pending_in',
          'online': false,
        },
      ],
    });
    await Future<void>.delayed(Duration.zero);
    expect(seen, hasLength(1));
    expect(seen.first, hasLength(2));
    final alice = seen.first.first;
    expect(alice.deviceId, 5);
    expect(alice.status, 'accepted');
    expect(alice.online, isTrue);
    expect(alice.latitude, 32.06);
    expect(alice.lastTime, isNotNull);
    await sub.cancel();
  });

  test('location.push broadcast (update) goes to updatesStream', () async {
    final client = MessagingClient();
    final updates = <FriendPositionUpdate>[];
    final pushes = <LocationPushResult>[];
    final sub1 = client.updatesStream.listen(updates.add);
    final sub2 = client.pushesStream.listen(pushes.add);
    client.handleMessageForTest({
      'type': 'location.push',
      'status': 'update',
      'from': {'id': 5, 'uniqueId': '11111111', 'name': 'Alice'},
      'position': {
        'latitude': 31.23,
        'longitude': 121.47,
        'speed': 1.5,
        'batteryLevel': 88,
      },
    });
    await Future<void>.delayed(Duration.zero);
    expect(updates, hasLength(1));
    expect(pushes, isEmpty);
    expect(updates.first.fromDeviceId, 5);
    expect(updates.first.latitude, 31.23);
    expect(updates.first.speed, 1.5);
    expect(updates.first.batteryLevel, 88);
    await sub1.cancel();
    await sub2.cancel();
  });

  test('location.push result (timeout/declined/position) goes to pushesStream',
      () async {
    final client = MessagingClient();
    final pushes = <LocationPushResult>[];
    final sub = client.pushesStream.listen(pushes.add);
    client.handleMessageForTest({
      'type': 'location.push',
      'requestId': 42,
      'status': 'declined',
    });
    client.handleMessageForTest({
      'type': 'location.push',
      'requestId': 43,
      'from': {'id': 5, 'uniqueId': '11111111'},
      'position': {'latitude': 30.5, 'longitude': 114.3},
    });
    await Future<void>.delayed(Duration.zero);
    expect(pushes, hasLength(2));
    expect(pushes[0].requestId, 42);
    expect(pushes[0].status, 'declined');
    expect(pushes[1].requestId, 43);
    expect(pushes[1].status, isNull);
    expect(pushes[1].latitude, 30.5);
    expect(pushes[1].fromDeviceId, 5);
    await sub.cancel();
  });

  test('location.request push goes to requestsStream', () async {
    final client = MessagingClient();
    final requests = <IncomingLocationRequest>[];
    final sub = client.requestsStream.listen(requests.add);
    client.handleMessageForTest({
      'type': 'location.request',
      'requestId': 7,
      'from': {'id': 9, 'uniqueId': '87654321', 'name': 'Bob'},
    });
    await Future<void>.delayed(Duration.zero);
    expect(requests, hasLength(1));
    expect(requests.first.requestId, 7);
    expect(requests.first.fromUniqueId, '87654321');
    await sub.cancel();
  });

  test('requestLocation ack is correlated by type queue', () async {
    final client = MessagingClient();
    // 没有真实连接：_call 只排队等待者，ack 由测试消息注入完成。
    final future = client.requestLocation('87654321');
    client.handleMessageForTest({
      'type': 'location.request',
      'success': true,
      'requestId': 11,
      'status': 'sent',
    });
    final ack = await future;
    expect(ack.requestId, 11);
    expect(ack.status, 'sent');
  });

  test('connection_replaced does not kill the channel state', () async {
    final client = MessagingClient();
    client.handleMessageForTest({
      'type': 'error',
      'reason': 'connection_replaced',
    });
    await Future<void>.delayed(Duration.zero);
    expect(client.status, MessagingStatus.disconnected);
  });

  test('unknown json payloads are ignored safely', () async {
    final client = MessagingClient();
    client.handleMessageForTest({'foo': 'bar'});
    client.handleMessageForTest({'type': 'unknown_type'});
    await Future<void>.delayed(Duration.zero);
    expect(client.status, MessagingStatus.disconnected);
  });
}
