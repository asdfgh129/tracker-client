import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/map/geo_point.dart';
import '../../../core/observability/logger.dart';
import '../../../core/providers.dart';
import '../../../domain/entities/models.dart';
import '../../../domain/failures.dart';
import '../../auth/application/session_controller.dart';
import '../../devices/application/devices_controller.dart'
    show positionFromRow, positionToRow;
import 'track_math.dart';

/// 历史查询范围（HIS-01：今日/昨日/7 天/自定义）。
class HistoryRange {
  const HistoryRange._(this.from, this.to);

  factory HistoryRange.today({DateTime Function()? now}) {
    final clock = now ?? () => DateTime.now();
    final base = clock();
    final start = DateTime(base.year, base.month, base.day);
    return HistoryRange._(start, start.add(const Duration(days: 1)));
  }

  factory HistoryRange.yesterday({DateTime Function()? now}) {
    final clock = now ?? () => DateTime.now();
    final base = clock();
    final start = DateTime(base.year, base.month, base.day)
        .subtract(const Duration(days: 1));
    return HistoryRange._(start, start.add(const Duration(days: 1)));
  }

  factory HistoryRange.lastDays(int days, {DateTime Function()? now}) {
    final clock = now ?? () => DateTime.now();
    final base = clock();
    final end = DateTime(base.year, base.month, base.day)
        .add(const Duration(days: 1));
    return HistoryRange._(end.subtract(Duration(days: days)), end);
  }

  factory HistoryRange.custom(DateTime from, DateTime to) {
    if (to.isBefore(from)) {
      throw const ConfigFailure('结束时间不能早于开始时间');
    }
    return HistoryRange._(from, to);
  }

  final DateTime from;
  final DateTime to;

  Duration get span => to.difference(from);

  /// 分段策略（docs/04 §3.3：按天或 6 小时分段，避免单次过大）。
  List<HistoryRange> segment() {
    const maxSegment = Duration(days: 2);
    if (span <= maxSegment) return [this];
    final segments = <HistoryRange>[];
    var cursor = from;
    while (cursor.isBefore(to)) {
      final next = cursor.add(maxSegment);
      final end = next.isAfter(to) ? to : next;
      segments.add(HistoryRange._(cursor, end));
      cursor = end;
    }
    return segments;
  }
}

/// 历史数据状态（HIS-01～HIS-08）。
///
/// 性能 P1-b：抽稀结果 [renderPoints] 在构造时**计算一次并缓存**，
/// 而不是 getter 每次 build 重算（10k 点 Douglas–Peucker 每帧重算
/// 会直接卡死回放页）。导出仍走 [points] 原始数据。
class HistoryState {
  HistoryState({
    this.points = const [],
    this.stops = const [],
    this.stats,
    this.loading = false,
    this.error,
    this.range,
  }) : renderPoints = points.length <= 2000
            ? points
            : TrackThinner.douglasPeucker(points, 12);

  final List<Position> points;
  final List<TrackStop> stops;
  final TrackStats? stats;
  final bool loading;
  final String? error;
  final HistoryRange? range;

  /// 地图渲染用的抽稀轨迹（构造时缓存）。
  final List<Position> renderPoints;

  HistoryState copyWith({
    List<Position>? points,
    List<TrackStop>? stops,
    TrackStats? stats,
    bool clearStats = false,
    bool? loading,
    String? error,
    bool clearError = false,
    HistoryRange? range,
  }) {
    return HistoryState(
      points: points ?? this.points,
      stops: stops ?? this.stops,
      stats: clearStats ? null : (stats ?? this.stats),
      loading: loading ?? this.loading,
      error: clearError ? null : error,
      range: range ?? this.range,
    );
  }
}

/// 历史控制器（family by deviceId）。
class HistoryController extends FamilyAsyncNotifier<HistoryState, int> {
  @override
  Future<HistoryState> build(int arg) async {
    // 默认今日（首屏 3 秒内绘制，docs/01 §3.6 验收）。
    final range = HistoryRange.today();
    final cached = await _loadFromCache(arg, range);
    unawaited(load(arg, range));
    return HistoryState(
      points: cached,
      range: range,
      stats: TrackStats.compute(cached),
      loading: true,
    );
  }

  Future<List<Position>> _loadFromCache(int deviceId, HistoryRange range) async {
    final session = ref.read(sessionControllerProvider).value;
    final serverId = session?.profile?.id;
    if (serverId == null) return const [];
    try {
      final rows = await ref
          .read(appDatabaseProvider)
          .historyPositions(serverId, deviceId, range.from, range.to);
      return rows.map(positionFromRow).toList();
    } on Object {
      return const [];
    }
  }

  /// 按范围加载（REST 分段 + 去重排序 + 缓存落库）。
  Future<void> load(int deviceId, HistoryRange range) async {
    final session = ref.read(sessionControllerProvider).value;
    final serverId = session?.profile?.id;
    if (session == null || serverId == null) {
      state = AsyncData(
        (state.valueOrNull ?? HistoryState())
            .copyWith(loading: false, error: '请先登录'),
      );
      return;
    }

    state = AsyncData(
      (state.valueOrNull ?? HistoryState(range: range)).copyWith(
        loading: true,
        clearError: true,
        range: range,
      ),
    );

    try {
      final api = ref.read(sessionControllerProvider.notifier).apiFor(session);
      final collected = <Position>[];
      for (final segment in range.segment()) {
        final batch = await api.getPositions(
          deviceId: deviceId,
          from: segment.from,
          to: segment.to,
        );
        collected.addAll(batch);
      }

      // fixTime 去重 + 排序（docs/04 §3.3）。
      final byKey = <String, Position>{};
      for (final point in collected) {
        final key = SocketKey.positionKeyLike(
          point.deviceId,
          point.fixTime?.millisecondsSinceEpoch ?? 0,
        );
        byKey[key] = point;
      }
      final points = byKey.values.toList()
        ..sort((a, b) => (a.fixTime ?? _epoch)
            .compareTo(b.fixTime ?? _epoch));

      // 落库供离线查看。
      await ref.read(appDatabaseProvider).upsertPositions(
            serverId,
            points.map(positionToRow(serverId)).toList(),
          );

      final stats = TrackStats.compute(points);
      final stops = StopDetector.detect(points);
      state = AsyncData(
        HistoryState(
          points: points,
          stops: stops,
          stats: stats,
          loading: false,
          range: range,
        ),
      );
    } on AppFailure catch (error) {
      AppLog.w('history', 'load failed: ${error.code ?? '-'}');
      state = AsyncData(
        (state.valueOrNull ?? HistoryState()).copyWith(
          loading: false,
          error: error.userMessage,
        ),
      );
    }
  }

  static final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0);
}

final historyControllerProvider =
    AsyncNotifierProvider.family<HistoryController, HistoryState, int>(
  HistoryController.new,
);

/// SocketClient 幂等键的公开包装（避免 history 依赖 socket 内部）。
abstract final class SocketKey {
  static String positionKeyLike(int deviceId, int fixTimeMs) =>
      '$deviceId:$fixTimeMs';
}

/// 回放游标（HIS-02：播放/暂停/倍速/进度）。
class PlaybackState {
  const PlaybackState({
    this.playing = false,
    this.speed = 1,
    this.index = 0,
    this.pointCount = 0,
  });

  final bool playing;
  final int speed;
  final int index;
  final int pointCount;

  PlaybackState copyWith({bool? playing, int? speed, int? index, int? pointCount}) {
    return PlaybackState(
      playing: playing ?? this.playing,
      speed: speed ?? this.speed,
      index: index ?? this.index,
      pointCount: pointCount ?? this.pointCount,
    );
  }
}

/// 回放控制（时间轴拖动时地图同步，docs/02 §3.8）。
///
/// 点数由 HistoryScreen 通过 [syncPointCount] 注入（family provider 无法
/// 无参读取），步进间隔固定 400ms / 倍速，保证不同数据规模下节奏一致。
class PlaybackController extends Notifier<PlaybackState> {
  @override
  PlaybackState build() => const PlaybackState();

  void syncPointCount(int count) {
    if (state.pointCount != count) {
      state = state.copyWith(pointCount: count, index: 0, playing: false);
    }
  }

  void toggle() {
    if (state.playing) {
      state = state.copyWith(playing: false);
      return;
    }
    if (state.pointCount == 0) return;
    state = state.copyWith(
      playing: true,
      index: state.index.clamp(0, state.pointCount - 1),
    );
    _scheduleNext();
  }

  void setSpeed(int speed) => state = state.copyWith(speed: speed.clamp(1, 8));

  void seek(int index) {
    if (state.pointCount == 0) return;
    state = state.copyWith(index: index.clamp(0, state.pointCount - 1));
  }

  void _scheduleNext() {
    if (!state.playing) return;
    if (state.index >= state.pointCount - 1) {
      state = state.copyWith(playing: false);
      return;
    }
    final stepMs = (400 / state.speed).round().clamp(20, 2000);
    Future<void>.delayed(Duration(milliseconds: stepMs), () {
      if (!state.playing) return;
      state = state.copyWith(index: state.index + 1);
      _scheduleNext();
    });
  }
}

final playbackProvider =
    NotifierProvider<PlaybackController, PlaybackState>(PlaybackController.new);

GeoPoint positionGeo(Position p) => GeoPoint(p.latitude, p.longitude);
