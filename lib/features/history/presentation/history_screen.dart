import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../app/theme.dart';
import '../../../app/widgets/common.dart';
import '../../../core/map/geo_point.dart';
import '../../../core/map/map_models.dart';
import '../../../core/map/tracker_map_view.dart';
import '../../../domain/entities/models.dart';
import '../../../l10n/app_localizations.dart';
import '../../devices/application/devices_controller.dart';
import '../../events/application/events_controller.dart';
import '../../settings/application/settings_controller.dart';
import '../application/history_controller.dart';
import '../application/track_export.dart';
import '../application/track_math.dart';

/// 历史回放（HIS-01～HIS-08，docs/02 §3.8）。
///
/// 时间轴拖动地图同步；倍速 1/2/4/8；停留列表；速度/海拔/电量曲线；导出。
class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({required this.deviceId, super.key});

  final int deviceId;

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  int _lastSyncedCount = -1;

  @override
  Widget build(BuildContext context) {
    return _buildBody(context, ref);
  }

  Widget _buildBody(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(historyControllerProvider(widget.deviceId));
    final playback = ref.watch(playbackProvider);
    final devices = ref.watch(devicesControllerProvider).valueOrNull;
    final deviceName =
        devices?.deviceById(widget.deviceId)?.name ?? '#${widget.deviceId}';
    final settings = ref.watch(settingsProvider);

    final points = state.valueOrNull?.points ?? const <Position>[];
    final renderPoints = state.valueOrNull?.renderPoints ?? points;
    // 性能 P2-d：写 provider 移出条件路径 —— 只在点数实际变化时同步，
    // 且不在 build 中途改变其它 provider 的状态。
    if (points.length != _lastSyncedCount) {
      _lastSyncedCount = points.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(playbackProvider.notifier).syncPointCount(points.length);
        }
      });
    }
    final cursor = playback.index.clamp(0, math.max(points.length - 1, 0)).toInt();
    final cursorPosition = points.isEmpty ? null : points[cursor];

    return Scaffold(
      appBar: AppBar(
        title: Text(deviceName),
        actions: [
          IconButton(
            tooltip: l10n.historyExport,
            icon: const Icon(Icons.ios_share),
            onPressed: points.isEmpty
                ? null
                : () => _showExportSheet(context, ref, deviceName, points),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                TrackerMapView(
                  markers: [
                    if (cursorPosition != null)
                      MapDeviceMarker(
                        deviceId: widget.deviceId,
                        label: deviceName,
                        point: GeoPoint(
                          cursorPosition.latitude,
                          cursorPosition.longitude,
                        ),
                        course: cursorPosition.course,
                        online: true,
                        isSelf: false,
                      ),
                  ],
                  trails: [
                    if (renderPoints.length > 1)
                      MapTrail(
                        deviceId: widget.deviceId,
                        points: [
                          for (final p in renderPoints)
                            GeoPoint(p.latitude, p.longitude),
                        ],
                      ),
                  ],
                  initialTarget: renderPoints.isEmpty
                      ? null
                      : GeoPoint(
                          renderPoints.first.latitude,
                          renderPoints.first.longitude,
                        ),
                ),
                if (state.valueOrNull?.loading ?? false)
                  const Positioned(
                    top: 12,
                    left: 0,
                    right: 0,
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
                if (state.valueOrNull?.error case final error?)
                  Positioned(
                    top: 12,
                    left: 16,
                    right: 16,
                    child: ErrorCard(
                      message: error,
                      onRetry: () => ref
                          .read(historyControllerProvider(widget.deviceId).notifier)
                          .load(widget.deviceId, HistoryRange.today()),
                    ),
                  ),
              ],
            ),
          ),

          // 指标摘要。
          if (state.valueOrNull?.stats case final stats?)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Wrap(
                spacing: 16,
                children: [
                  Text(l10n.historyDistance(
                      distanceValue(settings, stats.distanceMeters))),
                  Text(l10n.historyMaxSpeed(
                      speedValue(settings, stats.maxSpeedMps))),
                  Text(l10n.historyAvgSpeed(
                      speedValue(settings, stats.avgMovingSpeedMps))),
                  Text(l10n.historyPoints(points.length)),
                ],
              ),
            ),

          // 回放控制。
          if (points.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  IconButton.filledTonal(
                    onPressed: () =>
                        ref.read(playbackProvider.notifier).toggle(),
                    icon: Icon(
                      playback.playing ? Icons.pause : Icons.play_arrow,
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: cursor.toDouble(),
                      max: (points.length - 1).toDouble(),
                      divisions: points.length > 1 ? points.length - 1 : null,
                      onChanged: (value) => ref
                          .read(playbackProvider.notifier)
                          .seek(value.round()),
                    ),
                  ),
                  for (final speed in const [1, 2, 4, 8])
                    InkWell(
                      onTap: () =>
                          ref.read(playbackProvider.notifier).setSpeed(speed),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Text(
                          l10n.historySpeed(speed),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: playback.speed == speed
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),

          // 分段：路线 / 停留 / 图表。
          Expanded(
            child: DefaultTabController(
              length: 3,
              child: Column(
                children: [
                  TabBar(
                    tabs: [
                      Tab(text: l10n.historyTabStops),
                      Tab(text: l10n.historyTabCharts),
                      Tab(text: l10n.historyTabEvents),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _StopsList(deviceId: widget.deviceId),
                        _Charts(points: points),
                        _HistoryEvents(deviceId: widget.deviceId),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showExportSheet(
    BuildContext context,
    WidgetRef ref,
    String deviceName,
    List<Position> points,
  ) {
    final l10n = AppLocalizations.of(context);
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final format in TrackExportFormat.values)
              ListTile(
                leading: const Icon(Icons.file_download_outlined),
                title: Text(switch (format) {
                  TrackExportFormat.gpx => l10n.historyExportGpx,
                  TrackExportFormat.kml => l10n.historyExportKml,
                  TrackExportFormat.csv => l10n.historyExportCsv,
                }),
                onTap: () async {
                  Navigator.pop(context);
                  if (points.isEmpty) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(l10n.historyExportEmpty)),
                      );
                    }
                    return;
                  }
                  // 写临时文件后走系统分享（导出永远 WGS-84，docs/04 §6）。
                  final content = TrackExporter.export(
                    format,
                    deviceName: deviceName,
                    points: points,
                  );
                  // M-5：设备名来自服务端，需清洗后才能拼进文件名
                  //（防目录穿越 / 非法字符）；完整名称仍保留在导出内容里。
                  final safeName = TrackExporter.safeFileName(deviceName);
                  final dir = await getTemporaryDirectory();
                  final file = File(
                    '${dir.path}/trackerone_${safeName}_'
                    '${DateTime.now().millisecondsSinceEpoch}.${format.extension}',
                  );
                  await file.writeAsString(content, flush: true);
                  await SharePlus.instance.share(
                    ShareParams(
                      title: file.uri.pathSegments.last,
                      files: [XFile(file.path)],
                    ),
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          l10n.historyExportDone(switch (format) {
                            TrackExportFormat.gpx => l10n.historyExportGpx,
                            TrackExportFormat.kml => l10n.historyExportKml,
                            TrackExportFormat.csv => l10n.historyExportCsv,
                          }),
                        ),
                      ),
                    );
                  }
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// 停留列表（HIS-03）。
class _StopsList extends ConsumerWidget {
  const _StopsList({required this.deviceId});

  final int deviceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final stops = ref.watch(historyControllerProvider(deviceId)).valueOrNull?.stops ??
        const <TrackStop>[];

    if (stops.isEmpty) {
      return EmptyState(icon: Icons.pause_circle_outline, title: l10n.historyStopsEmpty);
    }
    return ListView.builder(
      itemCount: stops.length,
      itemBuilder: (context, index) {
        final stop = stops[index];
        final duration = stop.duration;
        final durationText = duration.inMinutes >= 60
            ? '${duration.inHours}h${duration.inMinutes % 60}m'
            : '${duration.inMinutes}m';
        return ListTile(
          leading: const Icon(Icons.pause_circle_outline),
          title: Text(
            '${stop.arrival.toLocal().hour.toString().padLeft(2, '0')}:'
            '${stop.arrival.toLocal().minute.toString().padLeft(2, '0')}',
          ),
          subtitle: Text(l10n.historyStopDuration(
            stop.arrival.toLocal().toString().substring(11, 16),
            stop.departure.toLocal().toString().substring(11, 16),
            durationText,
          )),
          trailing: Text('${stop.points.length}'),
        );
      },
    );
  }
}

/// 速度/海拔/电量曲线（HIS-04：CustomPainter，联动游标省略为静态曲线）。
class _Charts extends StatelessWidget {
  const _Charts({required this.points});

  final List<Position> points;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (points.isEmpty) {
      return Center(child: Text(l10n.historyLoadError));
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(l10n.historyChartSpeed),
        SizedBox(
          height: 100,
          child: CustomPaint(
            painter: _LineChartPainter(
              values: [
                for (final p in points) p.speedMetersPerSecond,
              ],
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(l10n.historyChartAltitude),
        SizedBox(
          height: 100,
          child: CustomPaint(
            painter: _LineChartPainter(
              values: [
                for (final p in points) p.altitude ?? 0,
              ],
              color: Theme.of(context).colorScheme.tertiary,
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(l10n.historyChartBattery),
        SizedBox(
          height: 100,
          child: CustomPaint(
            painter: _LineChartPainter(
              values: [
                for (final p in points) p.batteryLevel ?? 0,
              ],
              color: Theme.of(context).colorScheme.statusOnline,
            ),
          ),
        ),
      ],
    );
  }
}

class _LineChartPainter extends CustomPainter {
  _LineChartPainter({required this.values, required this.color});

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final maxV = values.reduce(math.max);
    final minV = values.reduce(math.min);
    final span = (maxV - minV) == 0 ? 1.0 : (maxV - minV);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;

    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = size.width * i / (values.length - 1);
      final y = size.height - (values[i] - minV) / span * size.height * 0.9 - 4;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_LineChartPainter oldDelegate) =>
      oldDelegate.values != values || oldDelegate.color != color;
}

/// 事件在时间轴上的标记（HIS-08：简化为当日事件列表）。
class _HistoryEvents extends ConsumerWidget {
  const _HistoryEvents({required this.deviceId});

  final int deviceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final events =
        ref.watch(eventsControllerProvider).valueOrNull?.items ?? const [];
    final deviceEvents = events
        .where((item) => item.event.deviceId == deviceId)
        .toList(growable: false);
    if (deviceEvents.isEmpty) {
      return EmptyState(
        icon: Icons.notifications_none,
        title: AppLocalizations.of(context).eventsEmpty,
      );
    }
    return ListView.builder(
      itemCount: deviceEvents.length,
      itemBuilder: (context, index) => ListTile(
        dense: true,
        leading: const Icon(Icons.flag_outlined, size: 18),
        title: Text(deviceEvents[index].event.type),
        subtitle: Text(
          deviceEvents[index].event.eventTime?.toLocal().toString() ?? '',
        ),
      ),
    );
  }
}
