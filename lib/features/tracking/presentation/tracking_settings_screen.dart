import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/preferences.dart';
import '../../../core/tracking/tracking_engine.dart';
import '../../../l10n/app_localizations.dart';
import '../../auth/application/session_controller.dart';
import '../application/tracking_controller.dart';
import '../application/tracking_profile.dart';

/// 跟踪配置（TRK-06/07/08，docs/02 §3.7）。
///
/// 预设 + 逐项微调；修改即时生效（applyConfig），高风险项二次确认。
class TrackingSettingsScreen extends ConsumerStatefulWidget {
  const TrackingSettingsScreen({super.key});

  @override
  ConsumerState<TrackingSettingsScreen> createState() =>
      _TrackingSettingsScreenState();
}

class _TrackingSettingsScreenState
    extends ConsumerState<TrackingSettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final prefs = ref.watch(prefsProvider);
    final session = ref.watch(sessionControllerProvider).valueOrNull;
    final store = TrackingPrefsStore(prefs);
    final config = store.load(
      reportUrl: session?.profile?.reportUrl ?? '',
      deviceId: prefs.getString(PrefKeys.trackingUniqueId) ?? '',
      notificationText: 'TrackerOne',
    );
    final preset = store.loadPreset();

    return Scaffold(
      appBar: AppBar(title: Text(l10n.trackingSettingsTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 预设。
          Text(l10n.trackingPreset),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final candidate in TrackingPreset.values)
                ChoiceChip(
                  label: Text(_presetLabel(l10n, candidate)),
                  selected: preset == candidate,
                  onSelected: (_) async {
                    await store.savePreset(candidate);
                    await _apply(store, session, prefs);
                  },
                ),
            ],
          ),
          const Divider(height: 32),

          // 位置。
          Text(l10n.trackingAccuracy),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final accuracy in TrackingAccuracy.values)
                ChoiceChip(
                  label: Text(_accuracyLabel(l10n, accuracy)),
                  selected: config.accuracy == accuracy,
                  onSelected: (_) async {
                    await _apply(
                      store,
                      session,
                      prefs,
                      patch: (c) => c.copyWith(accuracy: accuracy),
                      preset: TrackingPreset.custom,
                    );
                  },
                ),
            ],
          ),
          const SizedBox(height: 16),
          _SliderTile(
            label: l10n.trackingInterval,
            valueText: l10n.trackingIntervalValue(config.intervalSeconds),
            value: config.intervalSeconds.toDouble(),
            min: 10,
            max: 1800,
            divisions: 179,
            onChanged: (value) async {
              await _apply(
                store,
                session,
                prefs,
                patch: (c) => c.copyWith(intervalSeconds: value.round()),
                preset: TrackingPreset.custom,
              );
            },
          ),
          _SliderTile(
            label: l10n.trackingDistance,
            valueText: l10n.trackingDistanceValue(config.distanceMeters),
            value: config.distanceMeters.toDouble(),
            min: 0,
            max: 1000,
            divisions: 100,
            onChanged: (value) async {
              await _apply(
                store,
                session,
                prefs,
                patch: (c) => c.copyWith(distanceMeters: value.round()),
                preset: TrackingPreset.custom,
              );
            },
          ),
          _SliderTile(
            label: l10n.trackingAngle,
            valueText: l10n.trackingAngleValue(config.angleDegrees),
            value: config.angleDegrees.toDouble(),
            min: 0,
            max: 180,
            divisions: 36,
            onChanged: (value) async {
              await _apply(
                store,
                session,
                prefs,
                patch: (c) => c.copyWith(angleDegrees: value.round()),
                preset: TrackingPreset.custom,
              );
            },
          ),
          _SliderTile(
            label: l10n.trackingHeartbeat,
            valueText: l10n.trackingHeartbeatValue(
                config.heartbeatIntervalSeconds),
            value: config.heartbeatIntervalSeconds.toDouble(),
            min: 0,
            max: 600,
            divisions: 60,
            onChanged: (value) async {
              await _apply(
                store,
                session,
                prefs,
                patch: (c) =>
                    c.copyWith(heartbeatIntervalSeconds: value.round()),
                preset: TrackingPreset.custom,
              );
            },
          ),
          const Divider(height: 32),

          // 可靠性。
          SwitchListTile(
            value: config.buffer,
            title: Text(l10n.trackingBuffer),
            subtitle: Text(l10n.trackingBufferDesc),
            onChanged: (value) async {
              if (!value) {
                final confirmed = await _confirm(
                  context,
                  l10n.trackingBuffer,
                  l10n.trackingBufferOffWarn,
                );
                if (!confirmed) return;
              }
              await _apply(
                store,
                session,
                prefs,
                patch: (c) => c.copyWith(buffer: value),
                preset: TrackingPreset.custom,
              );
            },
          ),
          SwitchListTile(
            value: config.stopDetection,
            title: Text(l10n.trackingStopDetection),
            subtitle: Text(l10n.trackingStopDetectionDesc),
            onChanged: (value) async {
              await _apply(
                store,
                session,
                prefs,
                patch: (c) => c.copyWith(stopDetection: value),
                preset: TrackingPreset.custom,
              );
            },
          ),
          SwitchListTile(
            value: config.wakeLock,
            title: Text(l10n.trackingWakeLock),
            onChanged: (value) async {
              await _apply(
                store,
                session,
                prefs,
                patch: (c) => c.copyWith(wakeLock: value),
                preset: TrackingPreset.custom,
              );
            },
          ),
          SwitchListTile(
            value: config.preferPlatformProviders,
            title: Text(l10n.trackingPreferPlatform),
            subtitle: Text(l10n.trackingPreferPlatformDesc),
            onChanged: (value) async {
              await _apply(
                store,
                session,
                prefs,
                patch: (c) => c.copyWith(preferPlatformProviders: value),
                preset: TrackingPreset.custom,
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _apply(
    TrackingPrefsStore store,
    SessionState? session,
    Prefs prefs, {
    TrackingConfig Function(TrackingConfig)? patch,
    TrackingPreset? preset,
  }) async {
    final base = store.load(
      reportUrl: session?.profile?.reportUrl ?? '',
      deviceId: prefs.getString(PrefKeys.trackingUniqueId) ?? '',
      notificationText: 'TrackerOne',
    );
    var next = preset == null ? base : preset.applyTo(base);
    if (patch != null) {
      next = patch(next);
    }
    // 任何一次修改都要同时落盘「配置 + 预设」：
    // 只存配置而不把预设改成 custom，下次进入会被旧预设覆盖回弹。
    if (preset != null) {
      await store.savePreset(preset);
    }
    await store.save(next);
    // 运行中热生效（docs/05 §4.3）。
    await ref.read(trackingControllerProvider.notifier).applyConfig(next);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).trackingApplied),
          duration: const Duration(seconds: 1),
        ),
      );
      setState(() {});
    }
  }

  String _presetLabel(AppLocalizations l10n, TrackingPreset preset) =>
      switch (preset) {
        TrackingPreset.walking => l10n.presetWalking,
        TrackingPreset.driving => l10n.presetDriving,
        TrackingPreset.asset => l10n.presetAsset,
        TrackingPreset.highFrequency => l10n.presetHighFrequency,
        TrackingPreset.powerSaver => l10n.presetPowerSaver,
        TrackingPreset.custom => l10n.presetCustom,
      };

  String _accuracyLabel(AppLocalizations l10n, TrackingAccuracy accuracy) =>
      switch (accuracy) {
        TrackingAccuracy.highest => l10n.accuracyHighest,
        TrackingAccuracy.high => l10n.accuracyHigh,
        TrackingAccuracy.medium => l10n.accuracyMedium,
        TrackingAccuracy.low => l10n.accuracyLow,
      };
}

class _SliderTile extends StatelessWidget {
  const _SliderTile({
    required this.label,
    required this.valueText,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final String label;
  final String valueText;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: theme.textTheme.bodyMedium),
            Text(
              valueText,
              style: theme.textTheme.labelLarge
                  ?.copyWith(color: theme.colorScheme.primary),
            ),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

Future<bool> _confirm(
  BuildContext context,
  String title,
  String body,
) async {
  final l10n = AppLocalizations.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(body),
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
  return confirmed ?? false;
}
