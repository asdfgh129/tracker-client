import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trackerone/core/network/server_profile.dart';
import 'package:trackerone/core/network/traccar_api.dart';
import 'package:trackerone/domain/failures.dart';

/// P0 回归：`TraccarApi.login()` 曾经对 `late final Dio dio` 二次赋值，
/// 在发出请求前就抛 `LateInitializationError`，导致密码登录 100% 失败。
void main() {
  late HttpServer server;
  late ServerProfile profile;
  var sessionCalls = 0;

  setUp(() async {
    sessionCalls = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final response = request.response;
      if (request.method == 'POST' && request.uri.path == '/api/session') {
        sessionCalls++;
        if (sessionCalls == 1) {
          // 第一次：密码错误（非 TOTP），必须映射为 UnauthorizedFailure。
          response.statusCode = 401;
          response.headers.contentType = ContentType.json;
          response.write(jsonEncode({'error': 'invalid credentials'}));
        } else {
          response.statusCode = 200;
          response.headers.contentType = ContentType.json;
          response.write(
            jsonEncode({
              'id': 7,
              'name': 'Audit',
              'email': 'audit@example.com',
            }),
          );
        }
      } else if (request.method == 'POST' &&
          request.uri.path == '/api/session/token') {
        response.statusCode = 200;
        response.headers.contentType = ContentType.text;
        response.write('token-abc');
      } else {
        response.statusCode = 404;
      }
      await response.close();
    });

    profile = ServerProfile(
      id: 1,
      name: 'local',
      apiBaseUrl: 'http://127.0.0.1:${server.port}',
      reportUrl: 'http://127.0.0.1:5055',
    );
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('login 不再抛 LateInitializationError，失败映射为 AppFailure', () async {
    final api = TraccarApi(profile: profile);

    await expectLater(
      api.login('audit@example.com', 'wrong'),
      throwsA(isA<UnauthorizedFailure>()),
    );

    // 关键回归点：第一次调用已经重建过 dio，第二次调用不能再次崩溃。
    final account = await api.login('audit@example.com', 'right');
    expect(account.id, 7);
    expect(account.email, 'audit@example.com');
    expect(sessionCalls, 2);
  });

  test('login 后仍可用同一客户端换取长期 Token', () async {
    final api = TraccarApi(profile: profile);

    await expectLater(
      api.login('audit@example.com', 'wrong'),
      throwsA(isA<UnauthorizedFailure>()),
    );
    await api.login('audit@example.com', 'right');

    expect(await api.exchangeToken(), 'token-abc');
    expect(api.token, 'token-abc');
  });
}
