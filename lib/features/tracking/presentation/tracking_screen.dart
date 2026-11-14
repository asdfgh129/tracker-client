import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../app/theme.dart';
import '../../../app/widgets/common.dart';
import '../../../core/location/permission_service.dart';
import '../../../core/observability/logger.dart';
import '../../../core/storage/preferences.dart';
import '../../../domain/failures.dart';
import '../../../l10n/app_localizations.dart';
import '../../auth/application/session_controller.dart';
import '../../settings/application/settings_controller.dart';
import '../application/self_device_binder.dart';
import '../application/tracking_controller.dart';
import '../application/tracking_profile.dart';

/// 跟踪面板（TRK-03～TRK-12，docs/02 §3.6）。
class TrackingScreen extends ConsumerWidget {
  const TrackingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(trackingControllerProvider);
    final uniqueId = ref.watch(prefsProvider).getString(PrefKeys.trackingUniqueId);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.trackingTitle),
        actions: [
          IconButton(
            tooltip: l10n.trackingSettingsTitle,
            icon: const Icon(Icons.tune),
            onPressed: () => context.push('/tracking/settings'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 本机绑定卡。
          if (uniqueId == null || uniqueId.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(l10n.trackingUnconfigured,
                        style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text(l10n.trackingUnconfiguredHint,
                        style: theme.textTheme.bodySmall),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () => _bindDevice(context, ref),
                      child: Text(l10n.deviceBindButton),
                    ),
                  ],
                ),
              ),
            )
          else ...[
            state.when(
              data: (uiState) => _StatusCard(uiState: uiState),
              loading: () => const Card(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ),
              error: (error, _) => ErrorCard(
                message: error.toString(),
                onRetry: () => ref.invalidate(trackingControllerProvider),
              ),
            ),
            const SizedBox(height: 16),

            // 快捷操作（TRK-11）。
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _locateNow(context, ref),
                    icon: const Icon(Icons.gps_fixed, size: 18),
                    label: Text(l10n.trackingLocateNow),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      foregroundColor: theme.colorScheme.statusDanger,
                    ),
                    onPressed: () => _sendSos(context, ref),
                    icon: const Icon(Icons.emergency, size: 18),
                    label: Text(l10n.trackingSos),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _BatteryOptimizationHint(),
          ],
        ],
      ),
    );
  }

  Future<void> _bindDevice(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final binder = ref.read(selfDeviceBinderProvider);
    try {
      final result = await binder.bind();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.deviceBindOk(result.device.name)),
          ),
        );
        ref.invalidate(trackingControllerProvider);
      }
    } on ForbiddenFailure catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.userMessage)),
        );
      }
    } on AppFailure catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.userMessage)),
        );
      }
    }
  }

  Future<void> _locateNow(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    try {
      final ok =
          await ref.read(trackingControllerProvider.notifier).requestPosition();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ok ? l10n.trackingSosSent : l10n.trackingSosFailed)),
        );
      }
    } on AppFailure catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.userMessage)),
        );
      }
    }
  }

  Future<void> _sendSos(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.trackingSos),
        content: Text(l10n.trackingSosConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.commonConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      final ok = await ref.read(trackingControllerProvider.notifier).sendSos();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ok ? l10n.trackingSosSent : l10n.trackingSosFailed),
          ),
        );
      }
    } on AppFailure catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.userMessage)),
        );
      }
    }
  }
}

/// 状态卡片（TRK-09/10；颜色 + 图标 + 文案，docs/02 §3.6）。
class _StatusCard extends ConsumerWidget {
  const _StatusCard({required this.uiState});

  final TrackingUiState uiState;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final session = ref.watch(sessionControllerProvider).valueOrNull;
    final settings = ref.watch(settingsProvider);

    final (color, icon, title, body) = switch (uiState) {
      TrackingUnconfigured() => (
          theme.colorScheme.statusNeutral,
          Icons.stop_circle_outlined,
          l10n.trackingStopped,
          l10n.trackingUnconfiguredHint
        ),
      TrackingStopped() => (
          theme.colorScheme.statusNeutral,
          Icons.stop_circle_outlined,
          l10n.trackingStopped,
          ''
        ),
      TrackingStarting() => (
          theme.colorScheme.statusWarning,
          Icons.autorenew,
          l10n.trackingStarting,
          ''
        ),
      TrackingRunning(:final lastUploadAt, :final queueSize) => (
          theme.colorScheme.statusOnline,
          Icons.play_circle_filled,
          l10n.trackingRunning,
          _stateBody(l10n, lastUploadAt, queueSize),
        ),
      TrackingLimited(:final reason, :final lastUploadAt, :final queueSize) => (
          theme.colorScheme.statusWarning,
          Icons.battery_alert,
          l10n.trackingLimited(reason),
          _stateBody(l10n, lastUploadAt, queueSize),
        ),
      TrackingFailedState(:final message) => (
          theme.colorScheme.statusDanger,
          Icons.error_outline,
          l10n.trackingFailed(message),
          ''
        ),
    };

    final tracking = ref.watch(trackingControllerProvider.notifier);
    final isRunning = uiState is TrackingRunning || uiState is TrackingLimited;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(color: color),
                  ),
                ),
              ],
            ),
            if (body.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                body,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: isRunning
                    ? theme.colorScheme.errorContainer
                    : theme.colorScheme.primary,
                foregroundColor: isRunning
                    ? theme.colorScheme.onErrorContainer
                    : theme.colorScheme.onPrimary,
              ),
              onPressed: () async {
                if (isRunning) {
                  await tracking.stop();
                } else {
                  await _startWithConsent(context, ref);
                }
              },
              child: Text(isRunning
                  ? l10n.trackingStop
                  : uiState is TrackingStarting
                      ? l10n.trackingStarting
                      : l10n.trackingStart),
            ),
            if (session != null && !session.offline)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${Uri.tryParse(session.profile?.apiBaseUrl ?? '')?.host ?? ''}'
                  ' · ${settings.units == UnitSystem.metric ? 'metric' : 'imperial'}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _stateBody(
    AppLocalizations l10n,
    DateTime? lastUploadAt,
    int queueSize,
  ) {
    final lastUpload = lastUploadAt == null
        ? l10n.trackingNeverUploaded
        : l10n.trackingLastUpload(
            relativeTime(
              l10n.timeJustNow,
              l10n.timeSecondsAgo,
              l10n.timeMinutesAgo,
              l10n.timeHoursAgo,
              l10n.timeDaysAgo,
              lastUploadAt,
              DateTime.now(),
            ),
          );
    return '$lastUpload · ${l10n.trackingQueue(queueSize)}';
  }

  Future<void> _startWithConsent(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final notifier = ref.read(trackingControllerProvider.notifier);

    // 1) 后台定位单独同意（CN-06：行踪轨迹敏感个人信息）。
    if (notifier.backgroundConsentRequired) {
      final consented = await _showBackgroundConsent(context, ref);
      if (!consented) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.trackingConsentDeclinedHint)),
          );
        }
        return;
      }
      await notifier.setBackgroundConsent(true);
    }

    // 2) 权限预检 + 申请（docs/05 §5.2 顺序）。
    final service = const PermissionService();
    var foreground = await service.foregroundLocationStatus();
    if (foreground != PermissionStatus.granted) {
      foreground = await service.requestForegroundLocation();
    }
    if (foreground != PermissionStatus.granted) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.permPermanentlyDenied),
            action: SnackBarAction(
              label: l10n.commonOpenSettings,
              onPressed: openAppSettings,
            ),
          ),
        );
      }
      return;
    }
    final background = await service.backgroundLocationStatus();
    if (background != PermissionStatus.granted) {
      await service.requestBackgroundLocation();
    }
    await service.requestActivityRecognition();

    // 3) 启动。
    try {
      await notifier.start();
    } on AppFailure catch (error) {
      AppLog.e('tracking', 'start failed', error: error);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.userMessage)),
        );
      }
    }
  }

  Future<bool> _showBackgroundConsent(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final l10n = AppLocalizations.of(context);
    final session = ref.read(sessionControllerProvider).valueOrNull;
    final config = TrackingPrefsStore(ref.read(prefsProvider)).load(
      reportUrl: session?.profile?.reportUrl ?? '',
      deviceId: '',
      notificationText: '',
    );
    final host = Uri.tryParse(session?.profile?.apiBaseUrl ?? '')?.host ?? '-';

    final agreed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(l10n.trackingConsentTitle),
        content: Text(
          l10n.trackingConsentBody(
            config.intervalSeconds,
            config.distanceMeters,
            host,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.trackingConsentDecline),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.trackingConsentAgree),
          ),
        ],
      ),
    );
    return agreed ?? false;
  }
}

/// 厂商省电白名单引导提示（TRK-15）。
class _BatteryOptimizationHint extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Card(
      color: theme.colorScheme.surfaceContainerHighest,
      child: ListTile(
        leading: Icon(Icons.battery_saver, color: theme.colorScheme.statusWarning),
        title: Text(l10n.trackingBgRestricted, style: theme.textTheme.bodyMedium),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.push('/onboarding/permissions'),
      ),
    );
  }
}
