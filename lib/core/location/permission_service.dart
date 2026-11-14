import 'package:permission_handler/permission_handler.dart';

import '../observability/logger.dart';

/// 权限申请顺序（docs/05 §5.2，关键）：
///
/// ```
/// 通知 → 前台定位 → 用户主动点「开始上报」→ 后台定位 → 运动识别
/// ```
///
/// 绝不在首次启动申请后台定位（合规红线，docs/05 §12）。
class PermissionService {
  const PermissionService();

  Future<PermissionStatus> notificationStatus() =>
      Permission.notification.status;

  /// 通知权限：进入地图后首次申请（docs/09 §3.7），拒绝也可用应用内事件。
  Future<PermissionStatus> requestNotification() =>
      _request(Permission.notification);

  Future<PermissionStatus> foregroundLocationStatus() =>
      Permission.locationWhenInUse.status;

  Future<PermissionStatus> requestForegroundLocation() =>
      _request(Permission.locationWhenInUse);

  Future<PermissionStatus> backgroundLocationStatus() =>
      Permission.locationAlways.status;

  /// 后台定位：仅在用户主动开启上报时调用，此前必须完成「单独同意」（CN-06）。
  Future<PermissionStatus> requestBackgroundLocation() =>
      _request(Permission.locationAlways);

  Future<PermissionStatus> activityRecognitionStatus() =>
      Permission.activityRecognition.status;

  Future<PermissionStatus> requestActivityRecognition() =>
      _request(Permission.activityRecognition);

  /// 永久拒绝检测（docs/05 §5.3）：展示「去设置」而不是反复弹窗。
  Future<bool> isPermanentlyDenied(Permission permission) async {
    final status = await permission.status;
    return status == PermissionStatus.permanentlyDenied ||
        status == PermissionStatus.restricted;
  }

  Future<PermissionStatus> _request(Permission permission) async {
    try {
      return await permission.request();
    } on Object catch (error) {
      AppLog.w('permission', 'request ${permission.toString()} failed: $error');
      return permission.status;
    }
  }

  /// 跟踪前权限预检（docs/03 §15.3）。
  Future<TrackingPermissionReport> precheckForTracking() async {
    final foreground = await foregroundLocationStatus();
    final background = await backgroundLocationStatus();
    final granted = foreground == PermissionStatus.granted;
    return TrackingPermissionReport(
      foregroundGranted: granted,
      backgroundGranted: background == PermissionStatus.granted ||
          background == PermissionStatus.limited,
      foregroundDenied: foreground == PermissionStatus.permanentlyDenied ||
          foreground == PermissionStatus.restricted,
    );
  }
}

/// 跟踪权限预检结果。
class TrackingPermissionReport {
  const TrackingPermissionReport({
    required this.foregroundGranted,
    required this.backgroundGranted,
    required this.foregroundDenied,
  });

  final bool foregroundGranted;
  final bool backgroundGranted;
  final bool foregroundDenied;

  bool get canStartForeground => foregroundGranted;
}

/// 国产 ROM 厂商引导分类（docs/05 §6.3；文案在 UI 层做 i18n）。
enum VendorHints { xiaomi, huaweiHonor, oppoRealme, vivoIqoo, samsung, onePlusMeizu, generic }
