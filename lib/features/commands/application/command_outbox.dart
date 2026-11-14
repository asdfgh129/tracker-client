import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/observability/logger.dart';
import '../../../core/providers.dart';
import '../../../core/storage/database.dart';
import '../../../domain/failures.dart';
import '../../auth/application/session_controller.dart';

/// 指令发件箱：发送失败的指令先落库，待网络/会话恢复后自动补发。
///
/// 借鉴 A 实现（trackerone opencode 线）的持久指令队列语义（先入队、
/// 指数场景补发、进程被杀恢复），但复用本项目通用 PendingActions 表，
/// 不引入独立 schema：
/// - `kind = 'command.send'`，payload = JSON `{serverId, deviceId, type, attributes}`；
/// - 成功即删，失败累加 retries（超过 PendingActions maxRetries 自动过期）；
/// - 语义为 at-least-once：响应丢失时可能重复下发（与 A 一致，Traccar
///   指令均为幂等型：定位请求/周期上报开关）。
class CommandOutbox {
  CommandOutbox(this._ref);

  final Ref _ref;

  static const String kind = 'command.send';

  /// 把一条指令写入发件箱。
  Future<void> enqueue({
    required int serverId,
    required int deviceId,
    required String type,
    Map<String, dynamic> attributes = const {},
  }) async {
    final db = _ref.read(appDatabaseProvider);
    await db.enqueuePendingAction(
      PendingActionsCompanion.insert(
        kind: kind,
        payload: jsonEncode({
          'serverId': serverId,
          'deviceId': deviceId,
          'type': type,
          'attributes': attributes,
        }),
      ),
    );
    AppLog.i('command', 'outbox enqueue type=$type deviceId=$deviceId');
  }

  /// 补发所有可行的离线指令。返回成功补发的条数。
  ///
  /// 只处理当前激活服务器的记录（跨档案指令在切换回该档案时补发）；
  /// 单条失败不阻断队列，retries 由调用方累加，超限自动过期。
  Future<int> flush() async {
    final session = _ref.read(sessionControllerProvider).valueOrNull;
    final profileId = session?.profile?.id;
    if (session?.isAuthenticated != true || profileId == null) return 0;

    final db = _ref.read(appDatabaseProvider);
    final rows = await db.pendingActionRows(limit: 20);
    var sent = 0;
    for (final row in rows) {
      if (row.kind != kind) continue;
      final payload = _parse(row.payload);
      if (payload == null || payload['serverId'] != profileId) continue;

      try {
        await session!.api().sendCommand(
              deviceId: payload['deviceId'] as int,
              type: payload['type'] as String,
              attributes:
                  (payload['attributes'] as Map<String, dynamic>?) ?? const {},
            );
        await db.removePendingAction(row.id);
        sent++;
        AppLog.i(
          'command',
          'outbox flushed type=${payload['type']} deviceId=${payload['deviceId']}',
        );
      } on AppFailure catch (error) {
        // 401：会话过期，保留记录等重新登录后补发；其余失败累加 retries。
        final keepForRelogin = error is UnauthorizedFailure;
        if (!keepForRelogin) {
          await db.incrementRetries(row.id);
        }
        AppLog.w(
          'command',
          'outbox flush failed type=${payload['type']}: '
              '${error.runtimeType}（retries=${row.retries + 1}）',
        );
      } on Object {
        await db.incrementRetries(row.id);
      }
    }
    return sent;
  }

  Map<String, dynamic>? _parse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic> &&
          decoded['deviceId'] is int &&
          decoded['type'] is String) {
        return decoded;
      }
    } on Object {
      // payload 损坏：由调用方计入 retries，最终过期清除。
    }
    return null;
  }
}

final commandOutboxProvider =
    Provider<CommandOutbox>((ref) => CommandOutbox(ref));
