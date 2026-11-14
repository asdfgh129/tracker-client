import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:trackerone/core/network/socket_client.dart';

void main() {
  group('SocketClient.parseMessage (docs/04 §5.2)', () {
    // 每个用例独立实例：去重集合是实例状态。
    late SocketClient socket;
    setUp(() => socket = SocketClient());

    test('parses positions snapshot', () {
      final snapshot = socket.parseMessage(
        jsonEncode({
          'positions': [
            {
              'id': 1,
              'deviceId': 42,
              'latitude': 39.9,
              'longitude': 116.4,
              'fixTime': '2026-11-01T08:12:30.000+00:00',
              'speed': 10,
              'attributes': {'batteryLevel': 78},
            },
          ],
        }),
      );
      expect(snapshot.positions, hasLength(1));
      expect(snapshot.positions.first.deviceId, 42);
      expect(snapshot.positions.first.batteryLevel, 78);
    });

    test('dedups positions by (deviceId, fixTime)', () {
      final raw = jsonEncode({
        'positions': [
          {
            'id': 1,
            'deviceId': 42,
            'latitude': 39.9,
            'longitude': 116.4,
            'fixTime': '2026-11-01T08:12:30.000+00:00',
          },
          {
            'id': 2,
            'deviceId': 42,
            'latitude': 39.9,
            'longitude': 116.4,
            'fixTime': '2026-11-01T08:12:30.000+00:00',
          },
        ],
      });
      final snapshot = socket.parseMessage(raw);
      expect(snapshot.positions, hasLength(1));
    });

    test('dedups events by id', () {
      final first = socket.parseMessage(
        jsonEncode({
          'events': [
            {'id': 555, 'deviceId': 1, 'type': 'alarm'},
          ],
        }),
      );
      final second = socket.parseMessage(
        jsonEncode({
          'events': [
            {'id': 555, 'deviceId': 1, 'type': 'alarm'},
          ],
        }),
      );
      expect(first.events, hasLength(1));
      expect(second.events, isEmpty);
    });

    test('merges devices and ignores unknown keys', () {
      final snapshot = socket.parseMessage(
        jsonEncode({
          'devices': [
            {'id': 7, 'name': 'Phone', 'uniqueId': '12345678', 'status': 'online'},
          ],
          'logs': [
            {'x': 1},
          ],
        }),
      );
      expect(snapshot.devices, hasLength(1));
      expect(snapshot.devices.first.isOnline, isTrue);
    });

    test('garbage payload does not throw', () {
      expect(socket.parseMessage('not json'), const SocketSnapshot());
      expect(socket.parseMessage(''), const SocketSnapshot());
      expect(socket.parseMessage(null), const SocketSnapshot());
      expect(
        socket.parseMessage(jsonEncode([1, 2, 3])),
        const SocketSnapshot(),
      );
    });
  });
}
