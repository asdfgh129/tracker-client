import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trackerone/core/providers.dart';
import 'package:trackerone/core/storage/database.dart';
import 'package:trackerone/core/storage/preferences.dart';
import 'package:trackerone/core/storage/secure_store.dart';
import 'package:trackerone/features/auth/application/session_controller.dart';
import 'package:trackerone/features/server/application/server_profile_controller.dart';

/// P0 回归：会话恢复遇到 401 时必须回登录页，不能继续以
/// “authenticated + offline” 展示本地缓存（僵尸会话）。
class _FakeProfileController extends ServerProfileController {
  _FakeProfileController(this.row);

  final ServerProfileRow row;

  @override
  Future<ServerProfileState> build() async =>
      ServerProfileState(profiles: [row], active: row);
}

ServerProfileRow _row(String apiBaseUrl) => ServerProfileRow(
  id: 1,
  name: 'audit',
  apiBaseUrl: apiBaseUrl,
  reportUrl: 'http://127.0.0.1:5055',
  allowSelfSigned: false,
  isDemo: false,
  isActive: true,
  sortOrder: 0,
  createdAt: DateTime.utc(2026),
);

ProviderContainer _container({
  required String apiBaseUrl,
  required InMemoryPrefs prefs,
  required InMemorySecureStore secure,
}) {
  final row = _row(apiBaseUrl);
  return ProviderContainer(
    overrides: [
      prefsProvider.overrideWithValue(prefs),
      secureStoreProvider.overrideWithValue(secure),
      serverProfileControllerProvider.overrideWith(
        () => _FakeProfileController(row),
      ),
      // 会话恢复不读数据库，但避免未 override 时抛错。
      appDatabaseProvider.overrideWith((ref) => throw StateError('unused')),
    ],
  );
}

void main() {
  test('401 恢复失败 → anonymous，且 Secure 中的 Token 被清除', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.statusCode = 401;
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"error":"session expired"}');
      await request.response.close();
    });

    final prefs = InMemoryPrefs();
    final secure = InMemorySecureStore();
    await secure.write(SecureKeys.token(1), 'expired-token');

    final container = _container(
      apiBaseUrl: 'http://127.0.0.1:${server.port}',
      prefs: prefs,
      secure: secure,
    );
    addTearDown(container.dispose);
    addTearDown(() => server.close(force: true));

    await container.read(serverProfileControllerProvider.future);
    final session = await container.read(sessionControllerProvider.future);

    expect(session.phase, SessionPhase.anonymous);
    expect(session.isAuthenticated, isFalse);
    expect(session.offline, isFalse);
    expect(session.token, isNull);
    expect(await secure.read(SecureKeys.token(1)), isNull);
  });

  test('网络不可达 → 仍允许 authenticated + offline 只读降级', () async {
    // 先占一个端口再释放，确保连接被拒绝（而不是超时）。
    final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close(force: true);

    final prefs = InMemoryPrefs();
    final secure = InMemorySecureStore();
    await secure.write(SecureKeys.token(1), 'cached-token');

    final container = _container(
      apiBaseUrl: 'http://127.0.0.1:$port',
      prefs: prefs,
      secure: secure,
    );
    addTearDown(container.dispose);

    await container.read(serverProfileControllerProvider.future);
    final session = await container.read(sessionControllerProvider.future);

    expect(session.phase, SessionPhase.authenticated);
    expect(session.offline, isTrue);
    expect(session.token, 'cached-token');
    expect(await secure.read(SecureKeys.token(1)), 'cached-token');
  });
}
