import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/observability/logger.dart';
import '../../../core/providers.dart';
import '../../../core/storage/database.dart';
import '../../../core/storage/preferences.dart';
import '../../../core/tracking/sdk_tracking_engine.dart';
import '../../../core/tracking/tracking_engine.dart';
import '../../../domain/failures.dart';
import '../../auth/application/session_controller.dart';
import 'tracking_profile.dart';

/// 跟踪状态机（TRK-09，docs/01 §3.4）：
///
/// ```
/// 未配置 → 已停止 → 启动中 → 运行中 ⇄ 已暂停（系统限制）
///                     ↘ 失败（权限/配置）
/// ```
sealed class TrackingUiState {
  const TrackingUiState();
}

class TrackingUnconfigured extends TrackingUiState {
  const TrackingUnconfigured();
}

class TrackingStopped extends TrackingUiState {
  const TrackingStopped();
}

class TrackingStarting extends TrackingUiState {
  const TrackingStarting();
}

class TrackingRunning extends TrackingUiState {
  const TrackingRunning({
    required this.lastUploadAt,
    required this.queueSize,
    this.batteryLevel,
  });

  final DateTime? lastUploadAt;
  final int queueSize;
  final double? batteryLevel;
}

/// 已暂停（系统限制 / 队列积压等）。
class TrackingLimited extends TrackingUiState {
  const TrackingLimited({required this.reason, this.lastUploadAt, this.queueSize = 0});

  final String reason;
  final DateTime? lastUploadAt;
  final int queueSize;
}

class TrackingFailedState extends TrackingUiState {
  const TrackingFailedState(this.message);

  final String message;
}

/// 跟踪控制器：封装引擎、权限、配置热更新与状态广播（TRK-03～TRK-10）。
class TrackingController extends AsyncNotifier<TrackingUiState> {
  SdkTrackingEngine? _engine;
  StreamSubscription<TrackingEvent>? _events;
  bool _backgroundConsent = false;

  @override
  Future<TrackingUiState> build() async {
    final session = ref.watch(sessionControllerProvider).value;
    final profile = session?.profile;
    if (profile == null) return const TrackingUnconfigured();

    final prefs = ref.watch(prefsProvider);
    final uniqueId = prefs.getString(PrefKeys.trackingUniqueId);
    if (uniqueId == null || uniqueId.isEmpty) {
      return const TrackingUnconfigured();
    }

    _backgroundConsent =
        prefs.getBool(PrefKeys.backgroundLocationConsent) ?? false;

    // 引擎单例：配置变化用 applyConfig 热生效（TRK 验收：无需重启）。
    final engine = _engine ?? SdkTrackingEngine();
    _engine = engine;
    _events ??= engine.events.listen(_onEngineEvent);
    ref.onDispose(() {
      _events?.cancel();
      _events = null;
    });

    // 恢复真实状态（进程被杀后重开，状态与实际一致，docs/01 §3.4 验收）。
    try {
      final tracking = await engine.isTracking();
      if (tracking) {
        final snapshot = await _loadSnapshot();
        return TrackingRunning(
          lastUploadAt: snapshot?.$1,
          queueSize: snapshot?.$2 ?? 0,
        );
      }
      return const TrackingStopped();
    } on Object {
      return const TrackingStopped();
    }
  }

  TrackingConfig _currentConfig() {
    final session = ref.read(sessionControllerProvider).value;
    final profile = session!.profile!;
    final prefs = ref.read(prefsProvider);
    final store = TrackingPrefsStore(prefs);
    final uniqueId = prefs.getString(PrefKeys.trackingUniqueId)!;
    final brandName = 'TrackerOne';
    return store.load(
      reportUrl: profile.reportUrl,
      deviceId: uniqueId,
      notificationText: '$brandName → ${Uri.parse(profile.apiBaseUrl).host}',
    );
  }

  /// 开始上报（TRK-03）。权限不足抛 [PermissionFailure]。
  Future<void> start() async {
    final uniqueId = ref.read(prefsProvider).getString(PrefKeys.trackingUniqueId);
    if (uniqueId == null || uniqueId.isEmpty) {
      throw const ConfigFailure('请先绑定本机设备');
    }
    final session = ref.read(sessionControllerProvider).value;
    if (session?.profile == null) {
      throw const ConfigFailure('请先配置服务器');
    }
    // 离线只读 / 未登录不得启动上报（否则会绕过登录与同意门禁）。
    if (!(session?.isAuthenticated ?? false)) {
      throw const UnauthorizedFailure(message: '请先登录后再开始上报');
    }
    // CN-06：后台定位必须单独同意；远程 positionPeriodic 也必须经过此门禁。
    if (!_backgroundConsent) {
      throw const PermissionFailure('需要先同意后台上报位置');
    }

    state = const AsyncData(TrackingStarting());
    try {
      final engine = _engine ?? SdkTrackingEngine();
      final config = _currentConfig();
      await engine.init(config);
      await engine.start();

      _engine = engine;
      _events ??= engine.events.listen(_onEngineEvent);

      // 保存快照供诊断与状态恢复。
      await ref.read(appDatabaseProvider).saveTrackingSnapshot(
            TrackingSnapshotsCompanion.insert(
              id: session!.profile!.id ?? 0,
              uniqueId: uniqueId,
            ),
          );
      state = const AsyncData(TrackingRunning(lastUploadAt: null, queueSize: 0));
      AppLog.i('tracking', 'started (device=${uniqueId.length} digits)');
    } on AppFailure catch (error) {
      state = AsyncData(TrackingFailedState(error.userMessage));
      rethrow;
    } on Object catch (error) {
      final failure = TrackingFailure('无法启动上报：$error');
      state = AsyncData(TrackingFailedState(failure.userMessage));
      throw failure;
    }
  }

  /// 停止上报（TRK-03）。
  Future<void> stop() async {
    final engine = _engine;
    if (engine != null) {
      try {
        await engine.stop();
      } on Object catch (error) {
        AppLog.w('tracking', 'stop failed: $error');
      }
    }
    state = const AsyncData(TrackingStopped());
  }

  /// 单次定位（TRK-04）。
  Future<bool> requestPosition() async {
    final engine = _engine;
    if (engine == null) {
      throw const ConfigFailure('跟踪未启动，请先开始上报');
    }
    return engine.requestPosition();
  }

  /// SOS 上报（TRK-05：带 alarm 标记）。
  Future<bool> sendSos() async {
    final engine = _engine;
    if (engine == null) {
      throw const ConfigFailure('跟踪未启动，无法发送 SOS');
    }
    final ok = await engine.requestPosition(alarm: 'sos');
    AppLog.w('tracking', ok ? 'sos sent' : 'sos failed');
    return ok;
  }

  /// 配置热更新（TRK 验收：修改后无需重启）。
  Future<void> applyConfig(TrackingConfig config) async {
    await TrackingPrefsStore(ref.read(prefsProvider)).save(config);
    final engine = _engine;
    final running = state.valueOrNull is TrackingRunning ||
        state.valueOrNull is TrackingLimited;
    if (engine != null && running) {
      await engine.applyConfig(config);
    }
  }

  /// 后台定位「单独同意」结果记录（CN-06）。
  Future<void> setBackgroundConsent(bool agreed) async {
    _backgroundConsent = agreed;
    await ref.read(prefsProvider).setBool(PrefKeys.backgroundLocationConsent, agreed);
  }

  bool get backgroundConsentRequired => !_backgroundConsent;

  void _onEngineEvent(TrackingEvent event) {
    final current = state.valueOrNull;
    if (current == null) return;
    switch (event.type) {
      case TrackingEventType.started:
        state = AsyncData(
          TrackingRunning(lastUploadAt: null, queueSize: event.queueSize ?? 0),
        );
      case TrackingEventType.stopped:
        state = const AsyncData(TrackingStopped());
      case TrackingEventType.positionUploaded:
        final running = current is TrackingRunning
            ? current
            : const TrackingRunning(lastUploadAt: null, queueSize: 0);
        state = AsyncData(
          TrackingRunning(
            lastUploadAt: DateTime.now().toUtc(),
            queueSize: running.queueSize,
          ),
        );
        _saveSnapshot();
      case TrackingEventType.uploadFailed:
        state = AsyncData(
          TrackingLimited(
            reason: event.message ?? '上报失败，等待重试',
            lastUploadAt: current is TrackingRunning ? current.lastUploadAt : null,
          ),
        );
      case TrackingEventType.queueChanged:
        final running = current is TrackingRunning
            ? current
            : const TrackingRunning(lastUploadAt: null, queueSize: 0);
        final queue = event.queueSize ?? running.queueSize;
        // 队列积压 > 100 提示（docs/01 §3.4 验收）。
        state = AsyncData(
          queue > 100
              ? TrackingLimited(
                  reason: '待上传位置较多（$queue），等待网络恢复',
                  lastUploadAt: running.lastUploadAt,
                  queueSize: queue,
                )
              : TrackingRunning(
                  lastUploadAt: running.lastUploadAt,
                  queueSize: queue,
                ),
        );
        _saveSnapshot(queueSize: queue);
    }
  }

  Future<void> _saveSnapshot({int? queueSize}) async {
    try {
      final session = ref.read(sessionControllerProvider).value;
      final prefs = ref.read(prefsProvider);
      final uniqueId = prefs.getString(PrefKeys.trackingUniqueId);
      if (session?.profile?.id == null || uniqueId == null) return;
      final db = ref.read(appDatabaseProvider);
      final existing = await db.trackingSnapshot(session!.profile!.id!, uniqueId);
      await db.saveTrackingSnapshot(
        TrackingSnapshotsCompanion.insert(
          id: session.profile!.id!,
          uniqueId: uniqueId,
          lastUploadAt: Value(DateTime.now().toUtc()),
          queueSize: Value(queueSize ?? existing?.queueSize ?? 0),
        ),
      );
    } on Object catch (error) {
      AppLog.w('tracking', 'snapshot save failed: $error');
    }
  }

  Future<(DateTime?, int?)?> _loadSnapshot() async {
    try {
      final session = ref.read(sessionControllerProvider).value;
      final prefs = ref.read(prefsProvider);
      final uniqueId = prefs.getString(PrefKeys.trackingUniqueId);
      final serverId = session?.profile?.id;
      if (serverId == null || uniqueId == null) return null;
      final row = await ref
          .read(appDatabaseProvider)
          .trackingSnapshot(serverId, uniqueId);
      if (row == null) return null;
      return (row.lastUploadAt, row.queueSize);
    } on Object {
      return null;
    }
  }

  /// 引擎日志（TRK-16：上报日志查看与导出）。
  Future<List<TrackingLogEntry>> logs() async {
    final engine = _engine;
    if (engine == null) return const [];
    try {
      return await engine.getLogs();
    } on Object {
      return const [];
    }
  }
}

/// 内存中的 Token 不进这里；uniqueId 属设备标识存 Prefs（docs/03 §7.2/7.3）。
final trackingControllerProvider =
    AsyncNotifierProvider<TrackingController, TrackingUiState>(
  TrackingController.new,
);
