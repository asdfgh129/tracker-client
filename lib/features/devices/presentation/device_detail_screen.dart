import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/widgets/common.dart';
import '../../../domain/entities/models.dart';
import '../../../domain/failures.dart';
import '../../../l10n/app_localizations.dart';
import '../../commands/application/command_center.dart';
import '../../settings/application/settings_controller.dart';
import '../application/devices_controller.dart';

/// 设备详情（DEV-01/04/05：属性、状态、里程、指令）。
class DeviceDetailScreen extends ConsumerStatefulWidget {
  const DeviceDetailScreen({required this.deviceId, super.key});

  final int deviceId;

  @override
  ConsumerState<DeviceDetailScreen> createState() =>
      _DeviceDetailScreenState();
}

class _DeviceDetailScreenState extends ConsumerState<DeviceDetailScreen> {
  List<String>? _supportedCommands;

  @override
  void initState() {
    super.initState();
    _loadCommands();
  }

  Future<void> _loadCommands() async {
    try {
      final types =
          await ref.read(commandCenterProvider).supportedTypes(widget.deviceId);
      if (mounted) setState(() => _supportedCommands = types);
    } on AppFailure {
      if (mounted) setState(() => _supportedCommands = const []);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final devices = ref.watch(devicesControllerProvider).valueOrNull;
    final device = devices?.deviceById(widget.deviceId);
    final position = devices?.positionOf(widget.deviceId);
    final settings = ref.watch(settingsProvider);

    if (device == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.deviceDetailTitle)),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            EmptyState(
              icon: Icons.devices_other,
              title: l10n.deviceUnknown,
              actionLabel: l10n.commonRetry,
              onAction: () =>
                  ref.read(devicesControllerProvider.notifier).refresh(),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(device.name),
        actions: [
          IconButton(
            tooltip: l10n.deviceOpenHistory,
            icon: const Icon(Icons.history),
            onPressed: () => context.push('/device/${device.id}/history'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Row(
                    label: l10n.deviceStatusLabel,
                    value: device.status,
                  ),
                  if (position != null) ...[
                    _Row(
                      label: l10n.historyChartSpeed,
                      value: l10n.deviceSpeed(
                          speedValue(settings, position.speedMetersPerSecond)),
                    ),
                    if (position.altitude != null)
                      _Row(
                        label: l10n.historyChartAltitude,
                        value: '${position.altitude!.round()} m',
                      ),
                    if (position.batteryLevel != null)
                      _Row(
                        label: l10n.historyChartBattery,
                        value: '${position.batteryLevel!.round()}%',
                      ),
                    _Row(
                      label: l10n.lastUpdateLabel,
                      value: relativeTime(
                        l10n.timeJustNow,
                        l10n.timeSecondsAgo,
                        l10n.timeMinutesAgo,
                        l10n.timeHoursAgo,
                        l10n.timeDaysAgo,
                        device.lastUpdate,
                        DateTime.now(),
                      ),
                    ),
                    _Row(
                      label: l10n.deviceUniqueId,
                      value: device.uniqueId,
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(l10n.deviceCommands, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_supportedCommands == null)
            const LinearProgressIndicator(minHeight: 2)
          else if (_supportedCommands!.isEmpty)
            Text(l10n.deviceNoCommands, style: theme.textTheme.bodySmall)
          else
            Wrap(
              spacing: 8,
              children: [
                for (final type in _commandOrder(_supportedCommands!))
                  OutlinedButton(
                    onPressed: () => _sendCommand(context, device, type),
                    child: Text(_commandLabel(l10n, type)),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  /// 常用指令前置（positionSingle → positionPeriodic → positionStop → 其他）。
  List<String> _commandOrder(List<String> types) {
    const priority = ['positionSingle', 'positionPeriodic', 'positionStop'];
    final rest = types.where((t) => !priority.contains(t)).toList()..sort();
    return [...priority.where(types.contains), ...rest];
  }

  String _commandLabel(AppLocalizations l10n, String type) => switch (type) {
        'positionSingle' => l10n.commandPositionSingle,
        'positionPeriodic' => l10n.commandPositionPeriodic,
        'positionStop' => l10n.commandPositionStop,
        _ => type,
      };

  Future<void> _sendCommand(
    BuildContext context,
    Device device,
    String type,
  ) async {
    final l10n = AppLocalizations.of(context);
    try {
      final result = await ref
          .read(commandCenterProvider)
          .send(deviceId: device.id, type: type);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.queued
                ? l10n.deviceCommandQueued
                : l10n.deviceCommandSent,
          ),
        ),
      );
    } on AppFailure catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.deviceCommandFailed(error.userMessage))),
      );
    }
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(value, style: theme.textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}
