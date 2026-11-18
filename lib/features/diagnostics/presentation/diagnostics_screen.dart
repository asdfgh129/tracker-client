import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

import '../../../app/theme.dart';
import '../../../core/location/permission_service.dart';
import '../../../core/location/vendor_hints.dart';
import '../../../core/network/socket_client.dart';
import '../../../core/observability/log_sink.dart';
import '../../../core/observability/logger.dart';
import '../../../core/providers.dart';
import '../../../core/storage/preferences.dart';
import '../../../l10n/app_localizations.dart';
import '../../auth/application/session_controller.dart';
import '../../devices/application/devices_controller.dart';
import '../../tracking/application/tracking_controller.dart';
import '../application/diagnosis.dart';

/// 诊断页（SET-04，docs/05 §9；结论优先组织）。
class DiagnosticsScreen extends ConsumerStatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  ConsumerState<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends ConsumerState<DiagnosticsScreen> {
  bool _serverReachable = true;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _testServer());
  }

  Future<void> _testServer() async {
    setState(() => _testing = true);
    try {
      await ref
          .read(sessionControllerProvider.notifier)
          .refreshServerInfo();
      if (mounted) setState(() => _serverReachable = true);
    } on Object {
      if (mounted) setState(() => _serverReachable = false);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final session = ref.watch(sessionControllerProvider).valueOrNull;
    final devices = ref.watch(devicesControllerProvider).valueOrNull;
    final tracking = ref.watch(trackingControllerProvider).valueOrNull;

    final input = DiagnosisInput(
      // 真实权限在 [_completeInput] 中异步探测；加载完成前不假装已授权。
      foregroundGranted: false,
      backgroundGranted: false,
      notificationGranted: false,
      motionGranted: false,
      trackingRunning: tracking is TrackingRunning || tracking is TrackingLimited,
      lastFixAt: devices?.lastRefresh,
      lastUploadAt: tracking is TrackingRunning ? tracking.lastUploadAt : null,
      queueSize: tracking is TrackingRunning ? tracking.queueSize : 0,
      socketStatus: devices?.socketStatus ?? SocketStatus.disconnected,
      serverReachable: _serverReachable,
      clockSkewSeconds: 0,
      batteryOptimizationIgnored: false,
    );

    return FutureBuilder<DiagnosisInput>(
      future: _completeInput(input),
      builder: (context, snapshot) {
        final completed =
            snapshot.data ?? input;
        final conclusions = DiagnosisEngine.evaluate(completed);
        final overall = DiagnosisEngine.overall(conclusions);

        return Scaffold(
          appBar: AppBar(
            title: Text(l10n.diagTitle),
            actions: [
              IconButton(
                tooltip: l10n.diagLogsExport,
                icon: const Icon(Icons.ios_share),
                onPressed: () => _exportLogs(context),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // 总体状态。
              _OverallCard(severity: overall),
              const SizedBox(height: 16),

              // 结论卡（结论优先）。
              for (final conclusion in conclusions.where(
                (c) => c.severity != DiagnosisSeverity.ok,
              ))
                _ConclusionCard(conclusion: conclusion),
              const SizedBox(height: 16),

              // 权限。
              _SectionHeader(l10n.diagPermissions),
              _PermissionTile(
                label: l10n.diagPermForeground,
                status: completed.foregroundGranted,
              ),
              _PermissionTile(
                label: l10n.diagPermBackground,
                status: completed.backgroundGranted,
              ),
              _PermissionTile(
                label: l10n.diagPermNotification,
                status: completed.notificationGranted,
              ),
              _PermissionTile(
                label: l10n.diagPermMotion,
                status: completed.motionGranted,
              ),

              // 上报。
              _SectionHeader(l10n.diagTracking),
              ListTile(
                leading: const Icon(Icons.upload_outlined),
                title: Text(l10n.diagLastUpload),
                subtitle: Text(
                  tracking is TrackingRunning && tracking.lastUploadAt != null
                      ? tracking.lastUploadAt!.toLocal().toString()
                      : l10n.diagNeverUploaded,
                ),
              ),
              ListTile(
                leading: const Icon(Icons.inventory_2_outlined),
                title: Text(l10n.diagQueue),
                subtitle: Text('${completed.queueSize}'),
              ),
              FutureBuilder<int>(
                future: _commandOutboxCount(),
                builder: (context, snapshot) => ListTile(
                  leading: const Icon(Icons.outbox_outlined),
                  title: Text(l10n.diagCommandOutbox),
                  subtitle: Text('${snapshot.data ?? 0}'),
                ),
              ),

              // 网络。
              _SectionHeader(l10n.diagNetwork),
              ListTile(
                leading: Icon(
                  switch (completed.socketStatus) {
                    SocketStatus.connected => Icons.sensors,
                    SocketStatus.connecting => Icons.sensors_off_outlined,
                    SocketStatus.disconnected => Icons.sensors_off,
                  },
                  color: switch (completed.socketStatus) {
                    SocketStatus.connected => theme.colorScheme.statusOnline,
                    SocketStatus.connecting => theme.colorScheme.statusWarning,
                    SocketStatus.disconnected => theme.colorScheme.statusNeutral,
                  },
                ),
                title: Text(l10n.diagSocket),
                subtitle: Text(switch (completed.socketStatus) {
                  SocketStatus.connected => l10n.diagSocketConnected,
                  SocketStatus.connecting => l10n.diagSocketConnecting,
                  SocketStatus.disconnected => l10n.diagSocketDisconnected,
                }),
              ),
              ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: Text(l10n.diagServer),
                subtitle: Text(
                  '${session?.profile?.apiBaseUrl ?? '-'}\n'
                  'Traccar ${session?.serverVersion ?? '-'}',
                ),
                isThreeLine: true,
                trailing: _testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : IconButton(
                        icon: const Icon(Icons.wifi_tethering),
                        onPressed: _testServer,
                      ),
              ),
              // gcj02 部署告警（对齐审计 P2-4）：服务端入站会把
              // TrackerOne 的 WGS-84 上报误当 GCJ-02 反算，出站再转一次，
              // 自身轨迹与好友定位整体偏移约 500m。
              if ((ref
                      .watch(prefsProvider)
                      .getString(PrefKeys.serverCoordinateSystem) ??
                  '')
                  .toLowerCase() ==
              'gcj02')
                ListTile(
                  leading: Icon(Icons.explore_off,
                      color: theme.colorScheme.statusWarning),
                  title: Text(l10n.diagCoordModeTitle),
                  subtitle: Text(l10n.diagCoordModeWarning),
                  isThreeLine: true,
                ),

              // 设备 / 厂商引导。
              _SectionHeader(l10n.diagDevice),
              if (Platform.isAndroid) ...[
                ListTile(
                  leading: Icon(Icons.battery_alert,
                      color: theme.colorScheme.statusWarning),
                  title: Text(l10n.diagVendorHint),
                  subtitle: ref.watch(deviceVendorHintsProvider).when(
                        data: (hints) => Text(
                          VendorHintsResolver.localize(l10n, hints),
                        ),
                        loading: () => null,
                        error: (_, _) => Text(
                          VendorHintsResolver.localize(
                              l10n, VendorHints.generic),
                        ),
                      ),
                ),
                ListTile(
                  leading: const Icon(Icons.battery_saver_outlined),
                  title: Text(l10n.diagnosticsBatteryGuideAction),
                  subtitle: Text(l10n.batteryGuideIntro),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/diagnostics/battery'),
                ),
              ],
              FutureBuilder<String>(
                future: _deviceSummary(),
                builder: (context, snapshot) => ListTile(
                  leading: const Icon(Icons.phone_android),
                  title: Text(l10n.diagDevice),
                  subtitle: Text(snapshot.data ?? '-'),
                ),
              ),

              // 日志。
              _SectionHeader(l10n.diagLogs),
              _LogList(),
            ],
          ),
        );
      },
    );
  }

  Future<DiagnosisInput> _completeInput(DiagnosisInput base) async {
    final service = const PermissionService();
    final foreground = await service.foregroundLocationStatus();
    final background = await service.backgroundLocationStatus();
    final notification = await service.notificationStatus();
    final motion = await service.activityRecognitionStatus();
    // 电池优化豁免此前硬编码 false（结论引擎的电池规则从未生效）。
    bool batteryIgnored = false;
    try {
      final battery = await Permission.ignoreBatteryOptimizations.status;
      batteryIgnored = battery.isGranted;
    } on Object {
      // 桌面/测试环境无该权限 API，按未豁免处理。
    }
    // 时钟偏差：读服务器 Date 头（离线 / 只读会话时无法测量，保持 0）。
    int clockSkewSeconds = 0;
    try {
      final api = ref.read(sessionControllerProvider).valueOrNull?.api();
      final skew = await api?.serverClockSkew();
      if (skew != null) clockSkewSeconds = skew.inSeconds;
    } on Object {
      // 无会话 / 离线只读：保持未知。
    }
    return DiagnosisInput(
      foregroundGranted: foreground == PermissionStatus.granted,
      backgroundGranted: background == PermissionStatus.granted ||
          background == PermissionStatus.limited,
      notificationGranted: notification == PermissionStatus.granted ||
          notification == PermissionStatus.limited,
      motionGranted: motion == PermissionStatus.granted,
      trackingRunning: base.trackingRunning,
      lastFixAt: base.lastFixAt,
      lastUploadAt: base.lastUploadAt,
      queueSize: base.queueSize,
      socketStatus: base.socketStatus,
      serverReachable: base.serverReachable,
      clockSkewSeconds: clockSkewSeconds,
      batteryOptimizationIgnored: batteryIgnored,
    );
  }

  /// 指令发件箱积压量（离线补发队列，SET-04 指标表）。
  Future<int> _commandOutboxCount() async {
    try {
      return await ref.read(appDatabaseProvider).commandOutboxCount();
    } on Object {
      return 0;
    }
  }

  Future<String> _deviceSummary() async {
    try {
      final plugin = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final info = await plugin.androidInfo;
        return '${info.manufacturer} ${info.model} · API ${info.version.sdkInt}';
      }
      if (Platform.isIOS) {
        final info = await plugin.iosInfo;
        return '${info.utsname.machine} · iOS ${info.systemVersion}';
      }
      return Platform.operatingSystemVersion;
    } on Object {
      return '-';
    }
  }

  Future<void> _exportLogs(BuildContext context) async {
    final file = FileLogSink.instance?.file;
    if (file == null || !file.existsSync()) return;
    await SharePlus.instance.share(
      ShareParams(title: 'trackerone.log', files: [XFile(file.path)]),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 4),
      child: Text(
        title,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

class _OverallCard extends StatelessWidget {
  const _OverallCard({required this.severity});

  final DiagnosisSeverity severity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final (color, icon, text) = switch (severity) {
      DiagnosisSeverity.ok => (
          theme.colorScheme.statusOnline,
          Icons.check_circle,
          l10n.diagOk
        ),
      DiagnosisSeverity.warning => (
          theme.colorScheme.statusWarning,
          Icons.warning_amber,
          l10n.diagWarning
        ),
      DiagnosisSeverity.error => (
          theme.colorScheme.statusDanger,
          Icons.error,
          l10n.diagError
        ),
    };
    return Card(
      child: ListTile(
        leading: Icon(icon, color: color, size: 32),
        title: Text(l10n.diagOverall),
        subtitle: Text(text, style: TextStyle(color: color)),
      ),
    );
  }
}

/// 结论卡：是什么、为什么、怎么修（docs/05 §9.2）。
class _ConclusionCard extends ConsumerWidget {
  const _ConclusionCard({required this.conclusion});

  final DiagnosisConclusion conclusion;

  @override
  Widget build(BuildContext context, WidgetRef widgetRef) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final (text, actionLabel, onAction) = switch (conclusion.reason) {
      DiagnosisReason.noBackgroundPermission => (
          l10n.diagConclusionNoPermission,
          l10n.diagActionOpenSettings,
          openAppSettings as VoidCallback
        ),
      DiagnosisReason.noService => (
          l10n.diagConclusionNoService,
          l10n.diagActionRetryTracking,
          () => context.push('/tracking')
        ),
      DiagnosisReason.noFixUpdate => (
          l10n.diagConclusionNoFix,
          l10n.diagActionRetryTracking,
          () => context.push('/tracking')
        ),
      DiagnosisReason.noUpload => (
          l10n.diagConclusionNoUpload,
          l10n.diagActionTest,
          () {}
        ),
      DiagnosisReason.socketDown => (
          l10n.diagConclusionSocketDown,
          l10n.diagActionReconnect,
          () => widgetRef.read(socketClientProvider).resume()
        ),
      DiagnosisReason.allGood => ('', '', () {}),
    };

    return Card(
      color: conclusion.severity == DiagnosisSeverity.error
          ? theme.colorScheme.errorContainer
          : theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  conclusion.severity == DiagnosisSeverity.error
                      ? Icons.error_outline
                      : Icons.warning_amber,
                  color: conclusion.severity == DiagnosisSeverity.error
                      ? theme.colorScheme.error
                      : theme.colorScheme.statusWarning,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
              ],
            ),
            const SizedBox(height: 8),
            if (actionLabel.isNotEmpty)
              TextButton(
                onPressed: onAction,
                child: Text(actionLabel),
              ),
          ],
        ),
      ),
    );
  }
}

class _PermissionTile extends StatelessWidget {
  const _PermissionTile({required this.label, required this.status});

  final String label;
  final bool status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return ListTile(
      leading: Icon(
        status ? Icons.check_circle : Icons.cancel,
        color: status
            ? theme.colorScheme.statusOnline
            : theme.colorScheme.statusDanger,
      ),
      title: Text(label),
      trailing: status
          ? Text(l10n.permGranted, style: theme.textTheme.bodySmall)
          : TextButton(
              onPressed: openAppSettings,
              child: Text(l10n.commonOpenSettings),
            ),
    );
  }
}

class _LogList extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Card(
      child: SizedBox(
        height: 220,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            for (final entry in AppLog.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  entry.format(),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

