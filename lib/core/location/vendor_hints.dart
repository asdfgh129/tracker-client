import 'dart:io';

import '../../../l10n/app_localizations.dart';
import 'permission_service.dart';

/// 国产 ROM 引导（docs/05 §6.3）：按厂商展示对应图文，不展示通用长文。
abstract final class VendorHintsResolver {
  static VendorHints? _cached;

  /// 从设备制造商推断（device_info_plus 在调用处注入，避免 core 依赖平台）。
  static VendorHints detect({required String manufacturer}) {
    if (_cached != null) return _cached!;
    final m = manufacturer.toLowerCase();
    final result = switch (m) {
      _ when m.contains('xiaomi') || m.contains('redmi') => VendorHints.xiaomi,
      _ when m.contains('huawei') || m.contains('honor') =>
        VendorHints.huaweiHonor,
      _ when m.contains('oppo') || m.contains('realme') =>
        VendorHints.oppoRealme,
      _ when m.contains('vivo') || m.contains('iqoo') => VendorHints.vivoIqoo,
      _ when m.contains('samsung') => VendorHints.samsung,
      _ when m.contains('oneplus') || m.contains('meizu') =>
        VendorHints.onePlusMeizu,
      _ => VendorHints.generic,
    };
    _cached = result;
    return result;
  }

  /// 平台侧快速判断：仅 Android 有厂商限制。
  static VendorHints detectFromPlatform() {
    if (!Platform.isAndroid) return VendorHints.generic;
    // 无 manufacturer 信息时给通用提示；真机上由诊断页注入。
    return VendorHints.generic;
  }

  static String localize(AppLocalizations l10n, VendorHints hints) =>
      switch (hints) {
        VendorHints.xiaomi => l10n.vendorXiaomi,
        VendorHints.huaweiHonor => l10n.vendorHuawei,
        VendorHints.oppoRealme => l10n.vendorOppo,
        VendorHints.vivoIqoo => l10n.vendorVivo,
        VendorHints.samsung => l10n.vendorSamsung,
        VendorHints.onePlusMeizu => l10n.vendorOnePlus,
        VendorHints.generic => l10n.vendorGeneric,
      };
}
