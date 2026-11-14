import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../app/widgets/common.dart';
import '../../../core/map/tracker_map_view.dart';
import '../../../core/network/socket_client.dart';
import '../../../l10n/app_localizations.dart';
import '../../devices/application/devices_controller.dart';
import '../../settings/application/settings_controller.dart';
import '../application/map_controller.dart';

/// 实时地图（MAP-01～MAP-12，docs/02 §3.5）。
class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> with WidgetsBindingObserver {
  Timer? _refreshTicker;

  @override
  void initState() {
    super.initState();
    // 性能 P2-e：后台时暂停 30s 相对时间 ticker（避免不可见页持续唤醒 isolate）。
    WidgetsBinding.instance.addObserver(this);
    // 相对时间刷新（每 30s 重建时间文案，不重建地图）。
    _refreshTicker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refreshTicker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final devices = ref.watch(devicesControllerProvider).valueOrNull;
    final render = ref.watch(mapRenderProvider);
    final query = ref.watch(mapQueryProvider);

    final followTarget = render.targetOf(
      query.followDeviceId,
      devices?.positions ?? const {},
    );

    return Scaffold(
      body: Stack(
        children: [
          // 地图（唯一入口 TrackerMapView，内部处理隐私门与坐标转换）。
          Positioned.fill(
            child: GestureDetector(
              onPanDown: (_) =>
                  ref.read(mapQueryProvider.notifier).onUserPan(),
              child: TrackerMapView(
                markers: render.markers,
                friendMarkers: render.friendMarkers,
                trails: render.trails,
                initialTarget: followTarget ?? render.initialTarget,
                onMarkerTap: (marker) {
                  ref.read(mapQueryProvider.notifier).select(marker.deviceId);
                },
              ),
            ),
          ),

          // 悬浮顶栏：搜索 + 筛选 + 图层。
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      onChanged: (value) =>
                          ref.read(mapQueryProvider.notifier).setSearch(value),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: l10n.mapSearchHint,
                        prefixIcon: const Icon(Icons.search, size: 20),
                        filled: true,
                        fillColor: theme.colorScheme.surface,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _MapActionButton(
                    icon: Icons.filter_list,
                    tooltip: l10n.mapFilter,
                    onPressed: () => _showFilterSheet(l10n),
                  ),
                  const SizedBox(width: 8),
                  _MapActionButton(
                    icon: Icons.layers,
                    tooltip: l10n.mapLayers,
                    onPressed: () => _showLayerSheet(l10n),
                  ),
                ],
              ),
            ),
          ),

          // 跟随中提示。
          if (query.followDeviceId != null)
            Positioned(
              top: 72,
              left: 0,
              right: 0,
              child: Center(
                child: _FollowBanner(
                  label: l10n.mapFollowOn(
                    devices?.deviceById(query.followDeviceId!)?.name ?? '?',
                  ),
                  onCancel: () =>
                      ref.read(mapQueryProvider.notifier).setFollow(null),
                ),
              ),
            ),

          // 离线 / Socket 状态横幅。
          if (devices?.offline ?? false)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: OfflineBanner(
                lastUpdated: relativeTime(
                  l10n.timeJustNow,
                  l10n.timeSecondsAgo,
                  l10n.timeMinutesAgo,
                  l10n.timeHoursAgo,
                  l10n.timeDaysAgo,
                  devices?.lastRefresh,
                  DateTime.now(),
                ),
              ),
            ),

          // 空态。
          if (render.markers.isEmpty && !query.showOfflineOnly)
            Positioned.fill(
              top: 80,
              child: EmptyState(
                icon: Icons.travel_explore,
                title: l10n.mapNoDevices,
                subtitle: l10n.mapNoDevicesHint,
                actionLabel: l10n.deviceBindTitle,
                onAction: () => context.push('/tracking'),
              ),
            ),

          // 设备卡片（点击标记）。
          if (query.selectedDeviceId != null)
            Align(
              alignment: Alignment.bottomCenter,
              child: _DeviceCard(
                deviceId: query.selectedDeviceId!,
                onClose: () =>
                    ref.read(mapQueryProvider.notifier).select(null),
                onHistory: () =>
                    context.push('/device/${query.selectedDeviceId}/history'),
                onFollow: () => ref
                    .read(mapQueryProvider.notifier)
                    .setFollow(query.selectedDeviceId),
                onCommands: () =>
                    context.push('/device/${query.selectedDeviceId}'),
              ),
            ),

          // 定位按钮。
          Positioned(
            right: 16,
            bottom: 96,
            child: FloatingActionButton.small(
              heroTag: 'locate',
              tooltip: l10n.mapLocateMe,
              onPressed: () {
                // 高德 SDK 自带定位层；此处聚焦本机设备。
                final selfId = devices?.devices
                    .where((d) => d.attributes['isSelf'] == true)
                    .map((d) => d.id)
                    .firstOrNull;
                if (selfId != null) {
                  ref.read(mapQueryProvider.notifier).setFollow(selfId);
                }
              },
              child: const Icon(Icons.my_location),
            ),
          ),

          // Socket 状态点。
          Positioned(
            right: 16,
            top: 72,
            child: _SocketBadge(status: devices?.socketStatus ?? SocketStatus.disconnected),
          ),
        ],
      ),
    );
  }

  void _showFilterSheet(AppLocalizations l10n) {
    final query = ref.read(mapQueryProvider);
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile(
              value: query.showOfflineOnly,
              onChanged: (_) {
                ref.read(mapQueryProvider.notifier).toggleOfflineOnly();
                Navigator.pop(context);
              },
              title: Text(l10n.deviceOffline),
            ),
          ],
        ),
      ),
    );
  }

  void _showLayerSheet(AppLocalizations l10n) {
    final settings = ref.read(settingsProvider);
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile(
              value: settings.mapTrail,
              onChanged: (value) {
                ref.read(settingsProvider.notifier).setMapTrail(value);
                Navigator.pop(context);
              },
              title: Text(l10n.mapTrail),
            ),
            SwitchListTile(
              value: settings.mapCluster,
              onChanged: (value) {
                ref.read(settingsProvider.notifier).setMapCluster(value);
                Navigator.pop(context);
              },
              title: Text(l10n.mapCluster),
            ),
          ],
        ),
      ),
    );
  }
}

class _MapActionButton extends StatelessWidget {
  const _MapActionButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, size: 22),
        ),
      ),
    );
  }
}

class _FollowBanner extends StatelessWidget {
  const _FollowBanner({required this.label, required this.onCancel});

  final String label;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.primaryContainer,
      borderRadius: BorderRadius.circular(999),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.center_focus_strong,
                size: 16, color: theme.colorScheme.onPrimaryContainer),
            const SizedBox(width: 8),
            Text(label, style: theme.textTheme.labelLarge),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onCancel,
              child: Icon(Icons.close,
                  size: 16, color: theme.colorScheme.onPrimaryContainer),
            ),
          ],
        ),
      ),
    );
  }
}

class _SocketBadge extends StatelessWidget {
  const _SocketBadge({required this.status});

  final SocketStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (color, icon) = switch (status) {
      SocketStatus.connected => (
          theme.colorScheme.statusOnline,
          Icons.sensors
        ),
      SocketStatus.connecting => (
          theme.colorScheme.statusWarning,
          Icons.sensors_off_outlined
        ),
      SocketStatus.disconnected => (
          theme.colorScheme.statusNeutral,
          Icons.sensors_off
        ),
    };
    return CircleAvatar(
      radius: 14,
      backgroundColor: theme.colorScheme.surface,
      child: Icon(icon, size: 16, color: color),
    );
  }
}

/// 设备底部卡片（MAP-08，docs/02 §3.5）。
class _DeviceCard extends ConsumerWidget {
  const _DeviceCard({
    required this.deviceId,
    required this.onClose,
    required this.onHistory,
    required this.onFollow,
    required this.onCommands,
  });

  final int deviceId;
  final VoidCallback onClose;
  final VoidCallback onHistory;
  final VoidCallback onFollow;
  final VoidCallback onCommands;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final devices = ref.watch(devicesControllerProvider).valueOrNull;
    final device = devices?.deviceById(deviceId);
    final position = devices?.positionOf(deviceId);
    if (device == null) return const SizedBox.shrink();

    final settings = ref.watch(settingsProvider);
    final speedText = position == null
        ? null
        : speedValue(settings, position.speedMetersPerSecond);

    return SafeArea(
      child: Card(
        margin: const EdgeInsets.all(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      device.name,
                      style: theme.textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  StatusChip(
                    label: device.isOnline
                        ? l10n.deviceOnline
                        : l10n.deviceOffline,
                    color: device.isOnline
                        ? theme.colorScheme.statusOnline
                        : theme.colorScheme.statusNeutral,
                    icon: device.isOnline
                        ? Icons.circle
                        : Icons.circle_outlined,
                  ),
                  IconButton(
                    onPressed: onClose,
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 16,
                runSpacing: 4,
                children: [
                  if (position != null)
                    Text(l10n.deviceSpeed(speedText ?? '0'),
                        style: theme.textTheme.bodySmall),
                  if (position?.batteryLevel != null)
                    Text(
                      l10n.deviceBattery(
                          '${position!.batteryLevel!.round()}'),
                      style: theme.textTheme.bodySmall,
                    ),
                  Text(
                    l10n.deviceLastUpdate(
                      relativeTime(
                        l10n.timeJustNow,
                        l10n.timeSecondsAgo,
                        l10n.timeMinutesAgo,
                        l10n.timeHoursAgo,
                        l10n.timeDaysAgo,
                        device.lastUpdate,
                        DateTime.now(),
                      ),
                    ),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: onHistory,
                      icon: const Icon(Icons.history, size: 18),
                      label: Text(l10n.deviceOpenHistory),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onFollow,
                      icon: const Icon(Icons.center_focus_strong, size: 18),
                      label: Text(l10n.mapFollow),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onCommands,
                      icon: const Icon(Icons.settings_remote, size: 18),
                      label: Text(l10n.deviceSendCommand),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
