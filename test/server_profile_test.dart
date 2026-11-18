import 'package:flutter_test/flutter_test.dart';
import 'package:trackerone/core/network/server_profile.dart';

void main() {
  group('ServerAddressDeriver.derive (AUTH-02)', () {
    test('rule 1: bare host -> report :5055', () {
      final profile = ServerAddressDeriver.derive(input: 'https://track.example.com');
      expect(profile.apiBaseUrl, 'https://track.example.com');
      expect(profile.reportUrl, 'https://track.example.com:5055');
      expect(profile.name, 'track.example.com');
    });

    test('rule 2: :8082 -> api keeps port, report :5055', () {
      final profile =
          ServerAddressDeriver.derive(input: 'https://track.example.com:8082');
      expect(profile.apiBaseUrl, 'https://track.example.com:8082');
      expect(profile.reportUrl, 'https://track.example.com:5055');
    });

    test('rule 3: reverse proxy path -> api keeps path, report :5055', () {
      final profile = ServerAddressDeriver.derive(
        input: 'https://track.example.com/traccar',
      );
      expect(profile.apiBaseUrl, 'https://track.example.com/traccar');
      expect(profile.reportUrl, 'https://track.example.com:5055');
    });

    test('adds https scheme when missing', () {
      final profile = ServerAddressDeriver.derive(input: 'track.example.com');
      expect(profile.apiBaseUrl, startsWith('https://'));
    });

    test('rejects empty and malformed input', () {
      expect(
        () => ServerAddressDeriver.derive(input: ''),
        throwsA(isA<ServerAddressException>()),
      );
      expect(
        () => ServerAddressDeriver.derive(input: 'https://'),
        throwsA(isA<ServerAddressException>()),
      );
    });

    test('rejects plaintext http unless explicitly allowed', () {
      expect(
        () => ServerAddressDeriver.derive(input: 'http://10.0.0.2:8082'),
        throwsA(isA<ServerAddressException>()),
      );
      final allowed = ServerAddressDeriver.derive(
        input: 'http://10.0.0.2:8082',
        allowInsecure: true,
      );
      expect(allowed.apiBaseUrl, 'http://10.0.0.2:8082');
    });

    test('keeps allowInsecure consent on the derived profile', () {
      final profile = ServerAddressDeriver.derive(
        input: 'http://10.0.0.2:8082',
        allowInsecure: true,
      );
      // H-3：用户对明文 HTTP 的确认必须随档案持久化，否则重启后丢失。
      expect(profile.allowInsecure, isTrue);
    });

    test('rejects non-http(s) schemes', () {
      expect(
        () => ServerAddressDeriver.derive(input: 'ftp://10.0.0.2'),
        throwsA(isA<ServerAddressException>()),
      );
    });

    test('socket url uses ws scheme for http api', () {
      final profile = ServerAddressDeriver.derive(
        input: 'http://10.0.0.2:8082',
        allowInsecure: true,
      );
      expect(profile.socketUrl, 'ws://10.0.0.2:8082/api/socket');
    });

    test('messaging url derives host:5056/messaging with inherited scheme', () {
      final secure = ServerAddressDeriver.derive(
        input: 'https://track.example.com',
      );
      expect(secure.messagingUrl, 'wss://track.example.com:5056/messaging');

      final plain = ServerAddressDeriver.derive(
        input: 'http://10.0.0.2:8082',
        allowInsecure: true,
      );
      expect(plain.messagingUrl, 'ws://10.0.0.2:5056/messaging');

      final proxied = ServerAddressDeriver.derive(
        input: 'https://example.com/api',
      );
      // 5056 是独立端口，不走反代路径。
      expect(proxied.messagingUrl, 'wss://example.com:5056/messaging');
    });
  });

  group('ServerAddressDeriver.parseImport (AUTH-03)', () {
    test('parses traccar client QR url with device id', () {
      final parsed = ServerAddressDeriver.parseImport(
        'http://demo.traccar.org:5055?device=12345678',
      );
      expect(parsed.profile.reportUrl, 'http://demo.traccar.org:5055');
      expect(parsed.deviceUniqueId, '12345678');
    });

    test('parses JSON server profile', () {
      final parsed = ServerAddressDeriver.parseImport(
        '{"name":"My","apiBaseUrl":"https://a.com:8082","reportUrl":"https://a.com:5055"}',
      );
      expect(parsed.profile.apiBaseUrl, 'https://a.com:8082');
      expect(parsed.profile.name, 'My');
    });

    test('parses minimal JSON with serverUrl', () {
      final parsed = ServerAddressDeriver.parseImport(
        '{"serverUrl":"https://a.com","name":"Srv"}',
      );
      expect(parsed.profile.apiBaseUrl, 'https://a.com');
      expect(parsed.profile.name, 'Srv');
    });

    test('parses trackerone deep link', () {
      final parsed = ServerAddressDeriver.parseImport(
        'trackerone://server?url=https%3A%2F%2Ftrack.example.com',
      );
      expect(parsed.profile.apiBaseUrl, 'https://track.example.com');
    });

    test('rejects garbage', () {
      expect(
        () => ServerAddressDeriver.parseImport('not a server <<<'),
        throwsA(isA<ServerAddressException>()),
      );
      expect(
        () => ServerAddressDeriver.parseImport('{"foo":1}'),
        throwsA(isA<ServerAddressException>()),
      );
    });
  });

  test('profile JSON round trip', () {
    const profile = ServerProfile(
      id: 3,
      name: 'n',
      apiBaseUrl: 'https://a',
      reportUrl: 'https://a:5055',
      allowSelfSigned: true,
      allowInsecure: true,
    );
    final restored = ServerProfile.fromJson(profile.toJson());
    expect(restored.name, 'n');
    expect(restored.allowSelfSigned, isTrue);
    expect(restored.allowInsecure, isTrue);
  });
}
