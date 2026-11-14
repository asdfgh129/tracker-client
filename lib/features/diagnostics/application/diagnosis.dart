import 'package:permission_handler/permission_handler.dart';

import '../../../core/network/socket_client.dart';

/// 诊断输入快照（docs/05 §9.1 指标表）。
class DiagnosisInput {
  const DiagnosisInput({
    required this.foregroundGranted,
    required this.backgroundGranted,
    required this.notificationGranted,
    required this.motionGranted,
    required this.trackingRunning,
    required this.lastFixAt,
    required this.lastUploadAt,
    required this.queueSize,
    required this.socketStatus,
    required this.serverReachable,
    required this.clockSkewSeconds,
    required this.batteryOptimizationIgnored,
  });

  final bool foregroundGranted;
  final bool backgroundGranted;
  final bool notificationGranted;
  final bool motionGranted;

  final bool trackingRunning;
  final DateTime? lastFixAt;
  final DateTime? lastUploadAt;
  final int queueSize;

  final SocketStatus socketStatus;
  final bool serverReachable;
  final int clockSkewSeconds;
  final bool batteryOptimizationIgnored;
}

/// 诊断结论（docs/05 §9.2 结论引擎：「是什么、为什么、怎么修」）。
enum DiagnosisSeverity { ok, warning, error }

class DiagnosisConclusion {
  const DiagnosisConclusion({
    required this.severity,
    required this.reason,
    required this.action,
  });

  final DiagnosisSeverity severity;

  /// 结论原因分类（UI 层映射为文案）。
  final DiagnosisReason reason;

  /// 建议动作分类（UI 层映射为按钮）。
  final DiagnosisAction action;
}

enum DiagnosisReason {
  allGood,
  noBackgroundPermission,
  noService,
  noFixUpdate,
  noUpload,
  socketDown,
}

enum DiagnosisAction { openSettings, restartTracking, reconnect, testServer, none }

abstract final class DiagnosisEngine {
  /// 结论优先：按依赖顺序找到第一个问题（docs/05 §9.2）。
  static List<DiagnosisConclusion> evaluate(DiagnosisInput input) {
    final conclusions = <DiagnosisConclusion>[];

    // 1) 权限。
    if (!input.backgroundGranted) {
      conclusions.add(
        const DiagnosisConclusion(
          severity: DiagnosisSeverity.error,
          reason: DiagnosisReason.noBackgroundPermission,
          action: DiagnosisAction.openSettings,
        ),
      );
    }

    // 2) 跟踪服务。
    if (!input.trackingRunning) {
      conclusions.add(
        const DiagnosisConclusion(
          severity: DiagnosisSeverity.warning,
          reason: DiagnosisReason.noService,
          action: DiagnosisAction.restartTracking,
        ),
      );
    }

    // 3) 定位更新（10 分钟无 fix）。
    if (input.trackingRunning) {
      final lastFix = input.lastFixAt;
      if (lastFix == null) {
        conclusions.add(
          const DiagnosisConclusion(
            severity: DiagnosisSeverity.warning,
            reason: DiagnosisReason.noFixUpdate,
            action: DiagnosisAction.restartTracking,
          ),
        );
      } else {
        final age = DateTime.now().toUtc().difference(lastFix);
        if (age.inMinutes > 10) {
          conclusions.add(
            const DiagnosisConclusion(
              severity: DiagnosisSeverity.warning,
              reason: DiagnosisReason.noFixUpdate,
              action: DiagnosisAction.restartTracking,
            ),
          );
        }
      }
    }

    // 4) 上报（有定位但无上报 = 网络/服务器问题）。
    if (input.trackingRunning && input.queueSize > 0 && !input.serverReachable) {
      conclusions.add(
        const DiagnosisConclusion(
          severity: DiagnosisSeverity.error,
          reason: DiagnosisReason.noUpload,
          action: DiagnosisAction.testServer,
        ),
      );
    }

    // 5) 实时连接。
    if (input.socketStatus != SocketStatus.connected) {
      conclusions.add(
        const DiagnosisConclusion(
          severity: DiagnosisSeverity.warning,
          reason: DiagnosisReason.socketDown,
          action: DiagnosisAction.reconnect,
        ),
      );
    }

    if (conclusions.isEmpty) {
      conclusions.add(
        const DiagnosisConclusion(
          severity: DiagnosisSeverity.ok,
          reason: DiagnosisReason.allGood,
          action: DiagnosisAction.none,
        ),
      );
    }
    return conclusions;
  }

  /// 总体严重级。
  static DiagnosisSeverity overall(List<DiagnosisConclusion> conclusions) {
    if (conclusions.any((c) => c.severity == DiagnosisSeverity.error)) {
      return DiagnosisSeverity.error;
    }
    if (conclusions.any((c) => c.severity == DiagnosisSeverity.warning)) {
      return DiagnosisSeverity.warning;
    }
    return DiagnosisSeverity.ok;
  }

  /// 权限状态 → 展示行。
  static Future<PermissionStatus> statusOf(Permission permission) =>
      permission.status;
}
