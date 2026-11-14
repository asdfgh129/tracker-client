import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/build_config.dart';
import '../../../core/observability/logger.dart';
import '../../../core/push/push_gateway.dart';
import '../../../core/storage/preferences.dart';
import '../../../core/network/traccar_api.dart';
import '../../../domain/failures.dart';
import '../../auth/application/session_controller.dart';
import '../../tracking/application/tracking_controller.dart';

/// 远程指令（DEV-04/05/06）。
///
/// 发送：`POST /api/commands/send`；接收：推送 `extras.command`。
/// 本机指令在后台执行（不要求打开 App 的部分由推送 SDK 唤醒后立即执行）。
class CommandCenter {
  CommandCenter(this._ref);

  final Ref _ref;

  /// 发送指令（DEV-04）。返回排队/已发送状态；失败抛 [AppFailure]。
  Future<CommandResult> send({
    required int deviceId,
    required String type,
    Map<String, dynamic> attributes = const {},
  }) async {
    final session = _ref.read(sessionControllerProvider).value;
    if (!session!.isAuthenticated) throw const UnauthorizedFailure();
    try {
      final result = await session.api().sendCommand(
            deviceId: deviceId,
            type: type,
            attributes: attributes,
          );
      AppLog.i('command', 'sent type=$type queued=${result.queued}');
      return result;
    } on AppFailure catch (error) {
      AppLog.w('command', 'send failed type=$type: ${error.code ?? '-'}');
      rethrow;
    }
  }

  /// 该设备支持的指令类型（按协议过滤）。
  Future<List<String>> supportedTypes(int deviceId) =>
      _ref.read(sessionControllerProvider).value!.api().getCommandTypes(deviceId);

  /// 处理本机收到的远程指令（DEV-06，docs/01 §3.8）。
  ///
  /// 支持：`positionSingle`、`positionPeriodic`、`positionStop`、`factoryReset`。
  /// `factoryReset` 需要用户在 UI 二次确认（[factoryResetConfirmed]）。
  ///
  /// H-4：推送 payload 本质是不可信的远程输入。任何能投递消息的实体
  /// （泄露的推送密钥、被劫持的网关）都不应能静默停止他人设备的定位。
  /// 因此要求：
  /// 1. 消息带 HMAC 签名（`sig` 字段），用与网关共享的指令密钥校验；
  /// 2. 携带的 `userId` 必须等于当前登录用户；
  /// 3. 未解锁（生物识别锁）时拒绝执行控制面指令。
  Future<RemoteCommandOutcome> handleIncoming(PushMessage message) async {
    final command = message.command;
    if (command == null || command.isEmpty) return RemoteCommandOutcome.ignored;

    // 1) 会话与锁守卫（M-8）。
    final session = _ref.read(sessionControllerProvider).valueOrNull;
    if (session == null || !session.isAuthenticated) {
      AppLog.w('command', 'rejected: no authenticated session');
      return RemoteCommandOutcome.ignored;
    }
    if (!session.unlocked) {
      AppLog.w('command', 'rejected: app locked');
      return RemoteCommandOutcome.needsUnlock;
    }

    // 2) 验签与身份绑定（H-4）。
    final verification = await _verifyCommand(message, session.user?.id);
    if (verification != CommandVerification.ok) {
      AppLog.w(
        'command',
        'rejected unsigned/mismatched command: $command',
        code: verification.name,
      );
      return RemoteCommandOutcome.rejectedUntrusted;
    }

    // 审计日志（高风险指令必须有，docs/01 §3.8 验收）。
    AppLog.w('command', 'incoming remote command: $command');

    switch (command) {
      case 'positionSingle':
        try {
          await _ref.read(trackingControllerProvider.notifier).requestPosition();
          return RemoteCommandOutcome.executed;
        } on AppFailure catch (error) {
          AppLog.w('command', 'positionSingle failed: ${error.code ?? '-'}');
          return RemoteCommandOutcome.failed;
        }
      case 'positionPeriodic':
        // 恢复默认周期上报（若已停止则按当前配置启动）。
        try {
          await _ref.read(trackingControllerProvider.notifier).start();
          return RemoteCommandOutcome.executed;
        } on AppFailure {
          return RemoteCommandOutcome.failed;
        }
      case 'positionStop':
        await _ref.read(trackingControllerProvider.notifier).stop();
        return RemoteCommandOutcome.executed;
      case 'factoryReset':
        // 高风险：必须 UI 二次确认；此处只标记待确认。
        return RemoteCommandOutcome.needsConfirmation;
      default:
        AppLog.w('command', 'unsupported command ignored: $command');
        return RemoteCommandOutcome.ignored;
    }
  }

  /// H-4：校验指令消息的签名与用户绑定。
  ///
  /// 签名内容：`userId|command|issuedAt`（网关侧同构），
  /// 密钥：`--dart-define=COMMAND_HMAC_KEY`（与网关环境变量一致）。
  /// 未配置密钥时视为「未启用指令通道」——一律拒绝，
  /// 绝不允许无签名指令执行（fail-closed）。
  Future<CommandVerification> _verifyCommand(
    PushMessage message,
    int? currentUserId,
  ) async {
    final key = BuildConfig.commandHmacKey;
    if (key.isEmpty) return CommandVerification.noKeyConfigured;

    final sig = message.data['sig']?.toString();
    final issuedAtRaw = message.data['issuedAt']?.toString();
    final userIdRaw = message.data['userId']?.toString();
    if (sig == null || issuedAtRaw == null || userIdRaw == null) {
      return CommandVerification.missingSignature;
    }

    // 2a) 身份绑定：指令必须发给当前登录用户。
    final userId = int.tryParse(userIdRaw);
    if (userId == null || currentUserId == null || userId != currentUserId) {
      return CommandVerification.userMismatch;
    }

    // 2b) 时效性：拒绝过期指令（默认 5 分钟窗口，防重放）。
    final issuedAt = int.tryParse(issuedAtRaw);
    if (issuedAt == null) return CommandVerification.missingSignature;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if ((nowMs - issuedAt).abs() > const Duration(minutes: 5).inMilliseconds) {
      return CommandVerification.expired;
    }

    // 2c) HMAC 校验（常量时间比较）。
    final expected = base64Url.encode(
      Hmac(sha256, utf8.encode(key))
          .convert(utf8.encode('$userId|${message.command}|$issuedAt'))
          .bytes,
    );
    if (!_constantTimeEquals(expected, sig)) {
      return CommandVerification.badSignature;
    }
    return CommandVerification.ok;
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// `factoryReset` 二次确认后执行：停止上报 + 清空本地敏感配置。
  ///
  /// 保留服务器档案与 Token（用户重新登录成本低；服务端数据不受影响）。
  Future<void> factoryResetConfirmed() async {
    final tracking = _ref.read(trackingControllerProvider.notifier);
    await tracking.stop();
    final prefs = _ref.read(prefsProvider);
    await prefs.remove('tracking.deviceId');
    await prefs.remove('tracking.uniqueId');
    AppLog.w('command', 'factory reset executed (local tracking config cleared)');
  }
}

enum RemoteCommandOutcome {
  executed,
  failed,
  needsConfirmation,
  ignored,

  /// H-4：签名缺失/不匹配/过期/身份不符 —— 已拒绝执行。
  rejectedUntrusted,

  /// M-8：应用处于锁定状态，需用户解锁后再试。
  needsUnlock,
}

/// 指令签名校验结果。
enum CommandVerification {
  ok,
  noKeyConfigured,
  missingSignature,
  userMismatch,
  expired,
  badSignature,
}

/// 指令执行入口由 app.dart 注入 PushRouter.onCommand（A1 接线）：
/// 网关消息流 → CommandCenter.handleIncoming（验签/锁守卫/分发）。
final commandCenterProvider = Provider<CommandCenter>((ref) => CommandCenter(ref));

/// 诊断用：指令结果摘要（不打印队列内容）。
String commandResultSummary(CommandResult result) =>
    result.queued ? 'queued' : 'sent';
