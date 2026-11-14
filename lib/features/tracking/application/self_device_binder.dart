import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/observability/logger.dart';
import '../../../core/storage/preferences.dart';
import '../../../domain/entities/models.dart';
import '../../../domain/failures.dart';
import '../../auth/application/session_controller.dart';
import 'tracking_profile.dart';

/// 本机绑定结果（TRK-02）。
class BindResult {
  const BindResult({required this.device, required this.created});

  final Device device;

  /// true = 本次新建；false = 服务端已有，直接绑定。
  final bool created;
}

/// 本机设备注册/绑定（docs/01 §3.3）：
///
/// 1. `GET /api/devices?uniqueId=<id>` 查找；
/// 2. 不存在 → `POST /api/devices`（无权限时 403 → 提示联系管理员）；
/// 3. 保存 device id 到本地，地图高亮「本机」。
class SelfDeviceBinder {
  SelfDeviceBinder(this._ref);

  final Ref _ref;


  /// 生成并持久化本机 uniqueId（TRK-01，可被用户修改）。
  Future<String> ensureUniqueId({String? override}) async {
    final prefs = _ref.read(prefsProvider);
    final existing = prefs.getString(PrefKeys.trackingUniqueId);
    if (override != null && override.isNotEmpty) {
      await prefs.setString(PrefKeys.trackingUniqueId, override);
      return override;
    }
    if (existing != null && existing.isNotEmpty) return existing;
    final generated = generateUniqueUniqueId();
    await prefs.setString(PrefKeys.trackingUniqueId, generated);
    return generated;
  }

  /// 绑定本机设备。
  Future<BindResult> bind({String? displayName}) async {
    final session = _ref.read(sessionControllerProvider).value;
    if (session == null || session.profile?.id == null) {
      throw const ConfigFailure('请先配置服务器');
    }
    final api = _ref.read(sessionControllerProvider.notifier).apiFor(session);
    final uniqueId = await ensureUniqueId();

    // 1) 查找已有设备。
    final found = await api.getDevices(uniqueId: uniqueId);
    if (found.isNotEmpty) {
      final device = found.first;
      await _persistBound(device);
      return BindResult(device: device, created: false);
    }

    // 2) 创建设备（需要权限）。
    try {
      final device = await api.createDevice(
        name: displayName ?? '本机 ${deviceModelHint()}',
        uniqueId: uniqueId,
      );
      await _persistBound(device);
      return BindResult(device: device, created: true);
    } on ForbiddenFailure {
      throw ForbiddenFailure(
        message: '没有创建设备的权限，请联系管理员添加设备 $uniqueId',
      );
    }
  }

  Future<void> _persistBound(Device device) async {
    await _ref.read(prefsProvider).setInt(PrefKeys.trackingDeviceId, device.id);
    AppLog.i('tracking', 'self device bound id=${device.id}');
  }

  /// 已绑定的服务端设备 id（未绑定为 null）。
  int? boundDeviceId() =>
      _ref.read(prefsProvider).getInt(PrefKeys.trackingDeviceId);

  /// 诊断用的机型摘要（不采集 IMEI 等唯一标识）。
  static String deviceModelHint() {
    // 避免在应用层引入 device_info_plus 平台调用；名称可编辑。
    return 'TrackerOne';
  }
}

/// UI 通过 provider 获取（WidgetRef 与 Ref 类型隔离）。
final selfDeviceBinderProvider =
    Provider<SelfDeviceBinder>((ref) => SelfDeviceBinder(ref));
