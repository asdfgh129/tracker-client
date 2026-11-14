import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secure Storage 键规范（docs/03 §7.2）。
///
/// - Token / 密码只进本类，禁止写入 SharedPreferences 或日志；
/// - 按 serverId 隔离，多服务器档案互不影响；
/// - Android: Keystore 加密；iOS: Keychain。
abstract final class SecureKeys {
  static String token(int serverId) => 'auth.token.$serverId';

  /// 可选保存的密码（默认不保存，仅用户显式勾选「记住密码」）。
  static String password(int serverId) => 'auth.password.$serverId';

  /// 5056 消息通道的设备密码（好友体系；首次连接自动生成并注册到服务端）。
  static String messagingPassword(int serverId) =>
      'messaging.password.$serverId';

  /// 推送网关为该档案别名签发的指令签名密钥（H-4，注册时下发）。
  static String commandSecret(int serverId) => 'push.commandSecret.$serverId';

  static const biometricEnabled = 'auth.biometric.enabled';
}

/// Secure Storage 抽象。测试用内存实现。
abstract interface class SecureStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
  Future<void> clear();
}

/// flutter_secure_storage 实现。
///
/// iOS 使用 `first_unlock_this_device`（docs/03 §7.2）：解锁设备后才可读，
/// 阻止开机后未解锁状态下的静默读取。
class SecureSecureStore implements SecureStore {
  SecureSecureStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<void> clear() => _storage.deleteAll();
}

final secureStoreProvider = Provider<SecureStore>((ref) => SecureSecureStore());

/// 内存实现（测试）。
class InMemorySecureStore implements SecureStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);

  @override
  Future<void> clear() async => _values.clear();
}
