import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../app/theme.dart';
import '../../../core/location/permission_service.dart';
import '../../../core/location/vendor_hints.dart';
import '../../../l10n/app_localizations.dart';
import '../../settings/application/settings_controller.dart';

/// 权限向导（docs/02 §3.4）：三步，每步只申请一个权限，解释「为什么」。
///
/// 顺序（docs/05 §5.2）：通知 → 前台定位 → 后台定位 + 运动识别。
/// 每步都可「稍后再说」；开始跟踪前必须完成前台定位。
class PermissionWizardScreen extends ConsumerStatefulWidget {
  const PermissionWizardScreen({super.key});

  @override
  ConsumerState<PermissionWizardScreen> createState() =>
      _PermissionWizardScreenState();
}

class _PermissionWizardScreenState extends ConsumerState<PermissionWizardScreen> {
  int _step = 0;
  bool _backgroundRequested = false;

  static const int _totalSteps = 3;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    final (icon, title, desc, action) = switch (_step) {
      0 => (
          Icons.notifications_outlined,
          l10n.permNotificationTitle,
          l10n.permNotificationDesc,
          () async {
            await const PermissionService().requestNotification();
            _next();
          },
        ),
      1 => (
          Icons.location_on_outlined,
          l10n.permForegroundTitle,
          l10n.permForegroundDesc,
          () async {
            final status =
                await const PermissionService().requestForegroundLocation();
            if (status == PermissionStatus.permanentlyDenied && mounted) {
              _showPermanentlyDenied(l10n);
              return;
            }
            _next();
          },
        ),
      _ => (
          Icons.directions_walk_outlined,
          l10n.permBackgroundTitle,
          l10n.permBackgroundDesc,
          () async {
            final service = const PermissionService();
            await service.requestBackgroundLocation();
            await service.requestActivityRecognition();
            _backgroundRequested = true;
            _finish();
          },
        ),
    };

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.permWizardTitle),
        actions: [
          TextButton(
            onPressed: _finish,
            child: Text(l10n.commonSkip),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.permWizardStep(_step + 1, _totalSteps),
              style: theme.textTheme.labelLarge
                  ?.copyWith(color: theme.colorScheme.primary),
            ),
            const SizedBox(height: 24),
            Icon(icon, size: 64, color: theme.colorScheme.primary),
            const SizedBox(height: 24),
            Text(title, style: theme.textTheme.headlineSmall),
            const SizedBox(height: 12),
            Text(
              desc,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            if (_backgroundRequested)
              _VendorCard(l10n: l10n)
            else ...[
              FilledButton(onPressed: action, child: Text(l10n.commonNext)),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _next,
                child: Text(l10n.permLater),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _next() {
    if (_step < _totalSteps - 1) {
      setState(() => _step += 1);
    } else {
      _finish();
    }
  }

  void _finish() {
    if (!mounted) return;
    final mode = _mode();
    if (mode == UsageMode.track || mode == UsageMode.both) {
      context.go('/tracking');
    } else {
      context.go('/map');
    }
  }

  UsageMode _mode() {
    final container = ProviderScope.containerOf(context);
    return container.read(settingsProvider).mode;
  }

  void _showPermanentlyDenied(AppLocalizations l10n) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.permDenied),
        content: Text(l10n.permPermanentlyDenied),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await openAppSettings();
            },
            child: Text(l10n.commonOpenSettings),
          ),
        ],
      ),
    );
  }
}

/// 厂商省电白名单引导（docs/05 §6.3）：按检测到的 ROM 展示对应文案。
class _VendorCard extends ConsumerWidget {
  const _VendorCard({required this.l10n});

  final AppLocalizations l10n;

  String _hint(VendorHints hints) => VendorHintsResolver.localize(l10n, hints);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.battery_alert, color: theme.colorScheme.statusWarning),
                const SizedBox(width: 8),
                Text(l10n.vendorTitle, style: theme.textTheme.titleMedium),
              ],
            ),            const SizedBox(height: 8),
            Text(l10n.vendorDesc, style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            Text(
              ref.watch(deviceVendorHintsProvider).maybeWhen(
                    data: (hints) => _hint(hints),
                    orElse: () => _hint(VendorHints.generic),
                  ),
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => context.go('/map'),
              child: Text(l10n.vendorRecheck),
            ),
          ],
        ),
      ),
    );
  }
}
