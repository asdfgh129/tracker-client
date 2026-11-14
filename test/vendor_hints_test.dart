import 'package:flutter_test/flutter_test.dart';
import 'package:trackerone/core/location/permission_service.dart';
import 'package:trackerone/core/location/vendor_hints.dart';

/// detect() 是进程内一次性缓存：每次断言前重置，保证用例间与用例内隔离。
VendorHints detectOf(String manufacturer) {
  VendorHintsResolver.resetCache();
  return VendorHintsResolver.detect(manufacturer: manufacturer);
}

void main() {
  group('VendorHintsResolver.detect（厂商识别，自 opencode 线移植）', () {
    test('小米系（xiaomi/redmi/poco）→ xiaomi', () {
      expect(detectOf('Xiaomi'), VendorHints.xiaomi);
      expect(detectOf('redmi'), VendorHints.xiaomi);
      expect(detectOf('Xiaomi POCO, Ltd'), VendorHints.xiaomi);
    });

    test('华为系（huawei/honor）→ huaweiHonor', () {
      expect(detectOf('HUAWEI'), VendorHints.huaweiHonor);
      expect(detectOf('HONOR'), VendorHints.huaweiHonor);
    });

    test('OPPO 系（oppo/realme）→ oppoRealme', () {
      expect(detectOf('OPPO'), VendorHints.oppoRealme);
      expect(detectOf('realme'), VendorHints.oppoRealme);
      // OnePlus 在 B 线归入 onePlusMeizu 档（与 A 线的归档不同，见 meizu 用例）。
    });

    test('vivo 系（vivo/iqoo）→ vivoIqoo', () {
      expect(detectOf('vivo'), VendorHints.vivoIqoo);
      expect(detectOf('iQOO'), VendorHints.vivoIqoo);
    });

    test('三星 → samsung；未知厂商 → generic', () {
      expect(detectOf('samsung'), VendorHints.samsung);
      expect(detectOf('Google'), VendorHints.generic);
      expect(detectOf('unknown-brand'), VendorHints.generic);
    });

    test('meizu → onePlusMeizu（B 线扩展，A 无此档）', () {
      expect(detectOf('Meizu'), VendorHints.onePlusMeizu);
      expect(detectOf('OnePlus'), VendorHints.onePlusMeizu);
    });
  });
}
