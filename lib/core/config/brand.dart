import 'package:flutter/material.dart';

/// 品牌与全局常量。白标时优先修改本文件（或由构建脚本注入）。
abstract final class Brand {
  static const String appName = 'TrackerOne';
  static const String applicationId = 'com.example.trackerone';
  static const String deepLinkScheme = 'trackerone';

  static const String privacyUrl = 'https://example.com/privacy';
  static const String supportUrl = 'https://example.com/support';

  /// CN-08：APP 备案号（如 `京ICP备XXXXXXXX号-1A`）。
  /// 空 = 「关于」页展示「备案审批中」占位；上线前必须替换。
  static const String appFilingNumber = String.fromEnvironment(
    'APP_FILING_NUMBER',
  );

  /// CN-08：高德底图审图号（GS(20XX)XXX号）。
  /// 空 = 展示占位；申请 Key 通过后从高德控制台获取并注入。
  static const String mapApprovalNumber = String.fromEnvironment(
    'MAP_APPROVAL_NUMBER',
  );

  /// 仅用于首次体验，正式环境必须替换为用户自己的服务器。
  static const String demoServerUrl = 'https://demo.traccar.org';

  static const Color seedColor = Color(0xFF0B6BCB);

  /// 仅用于海外 / 自托管兜底；中国大陆首发使用高德。
  /// OSM 公共瓦片仅适合开发；生产必须使用有授权的瓦片服务。
  static const String defaultTileUrl =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const String defaultTileAttribution = '© OpenStreetMap contributors';
}
