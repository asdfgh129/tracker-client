import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../app/widgets/common.dart';
import '../../../domain/entities/models.dart';
import '../../../l10n/app_localizations.dart';
import '../../auth/application/session_controller.dart';
import '../../settings/application/settings_controller.dart';
import '../application/devices_controller.dart';

/// 设备列表（MAP-01/07：状态、电量、速度、最后更新、搜索筛选）。
class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key});

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> with WidgetsBindingObserver {
  Timer? _ticker;
  String _query = '';

  @override
  void initState() {
    super.initState();
    // 性能 P2-e：后台时暂停 30s 相对时间 ticker（避免不可见页持续唤醒 isolate）。
    WidgetsBinding.instance.addObserver(this);
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _ticker ??= Timer.periodic(const Duration(seconds: 30), (_) {
        if (mounted) setState(() {});
      });
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(devicesControllerProvider);
    final session = ref.watch(sessionControllerProvider).valueOrNull;

    final devices = (state.valueOrNull?.devices ?? const <Device>[])
        .where((device) =>
            _query.isEmpty ||
            device.name.toLowerCase().contains(_query.toLowerCase()) ||
            device.uniqueId.contains(_query))
        .toList()
      ..sort((a, b) {
        // 在线优先，其余按名称。
        if (a.isOnline != b.isOnline) return a.isOnline ? -1 : 1;
        return a.name.compareTo(b.name);
      });

    final l10nTime = relativeTime(
      l10n.timeJustNow,
      l10n.timeSecondsAgo,
      l10n.timeMinutesAgo,
      l10n.timeHoursAgo,
      l10n.timeDaysAgo,
      null,
      DateTime.now(),
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.deviceListTitle),
        actions: [
          IconButton(
            onPressed: () =>
                ref.read(devicesControllerProvider.notifier).refresh(),
            icon: const Icon(Icons.refresh),
            tooltip: l10n.commonRefresh,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: l10n.mapSearchHint,
              ),
            ),
          ),
          if (state.valueOrNull?.offline ?? false)
            OfflineBanner(lastUpdated: l10nTime),
          Expanded(
            child: state.isLoading
                ? const ListSkeleton()
                : devices.isEmpty
                    ? EmptyState(
                        icon: Icons.devices_other,
                        title: l10n.mapNoDevices,
                        subtitle: l10n.mapNoDevicesHint,
                      )
                    : RefreshIndicator(
                        onRefresh: () => ref
                            .read(devicesControllerProvider.notifier)
                            .refresh(),
                        child: ListView.builder(
                          itemCount: devices.length,
                          itemBuilder: (context, index) =>
                              _DeviceTile(device: devices[index]),
                        ),
                      ),
          ),
          if (session?.isAuthenticated ?? false)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                l10n.deviceLastUpdate(l10nTime),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DeviceTile extends ConsumerWidget {
  const _DeviceTile({required this.device});

  final Device device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final position =
        ref.watch(devicesControllerProvider).valueOrNull?.positionOf(device.id);
    final settings = ref.watch(settingsProvider);

    final (color, icon) = switch (device.status) {
      'online' => (
          theme.colorScheme.statusOnline,
          Icons.check_circle_outline
        ),
      'offline' => (theme.colorScheme.statusNeutral, Icons.circle_outlined),
      _ => (theme.colorScheme.statusWarning, Icons.help_outline),
    };

    final lastSeen = relativeTime(
      l10n.timeJustNow,
      l10n.timeSecondsAgo,
      l10n.timeMinutesAgo,
      l10n.timeHoursAgo,
      l10n.timeDaysAgo,
      device.lastUpdate,
      DateTime.now(),
    );

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(device.name, overflow: TextOverflow.ellipsis),
        subtitle: Wrap(
          spacing: 12,
          children: [
            if (position != null)
              Text(l10n.deviceSpeed(speedValue(settings, position.speedMetersPerSecond))),
            if (position?.batteryLevel != null)
              Text(l10n.deviceBattery('${position!.batteryLevel!.round()}')),
            Text(
              device.isOnline
                  ? l10n.deviceOnline
                  : l10n.deviceStatusOffline(lastSeen),
            ),
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.push('/device/${device.id}'),
      ),
    );
  }
}
