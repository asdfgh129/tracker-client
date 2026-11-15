import 'package:flutter_test/flutter_test.dart';
import 'package:trackerone/core/network/traccar_api.dart';

void main() {
  group('ServerInfo（/api/server 字段提取）', () {
    test('reads nested attributes.version (real Traccar shape)', () {
      // Traccar 模型 attributes 经 Jackson 序列化为嵌套对象，
      // 顶层不存在 version——此前读顶层恒为 null（审计复核新发现）。
      final server = {
        'id': 1,
        'name': 'TrackerOne',
        'attributes': {
          'version': '6.16.0-CN-1.2',
          'coordinateSystem': 'wgs84',
        },
      };

      expect(ServerInfo.versionOf(server), '6.16.0-CN-1.2');
      expect(ServerInfo.coordinateSystemOf(server), 'wgs84');
    });

    test('falls back to top-level fields (flattened payloads)', () {
      final server = {'version': '6.16.0', 'coordinateSystem': 'gcj02'};

      expect(ServerInfo.versionOf(server), '6.16.0');
      expect(ServerInfo.coordinateSystemOf(server), 'gcj02');
    });

    test('missing fields return null (probe shows -)', () {
      expect(ServerInfo.versionOf({'id': 1}), isNull);
      expect(ServerInfo.coordinateSystemOf({'attributes': 'not-a-map'}),
          isNull);
    });

    test('reads top-level openid booleans (OIDC 0.5.0)', () {
      // openIdEnabled/openIdForce 是 Server 模型顶层字段（非 attributes）。
      final server = {
        'id': 1,
        'openIdEnabled': true,
        'openIdForce': false,
        'attributes': {'version': '6.16.0-CN-1.3'},
      };

      expect(ServerInfo.openIdEnabledOf(server), isTrue);
      expect(ServerInfo.openIdForceOf(server), isFalse);
    });

    test('openid booleans missing or malformed → null', () {
      expect(ServerInfo.openIdEnabledOf({'id': 1}), isNull);
      expect(ServerInfo.openIdForceOf({'openIdEnabled': 'yes'}), isNull);
    });
  });
}
