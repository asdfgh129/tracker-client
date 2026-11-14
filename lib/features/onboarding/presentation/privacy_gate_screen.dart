import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/config/brand.dart';
import '../../settings/application/settings_controller.dart';
import '../../../l10n/app_localizations.dart';

/// 首次启动隐私同意门（CN-05）。
///
/// 同意前**不初始化**任何第三方 SDK（地图/推送/统计）——
/// 由 TrackerMapView 的隐私门与 PushProvider 的选择共同保证。
class PrivacyGateScreen extends ConsumerWidget {
  const PrivacyGateScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Icon(
                Icons.privacy_tip_outlined,
                size: 56,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                l10n.privacyTitle,
                style: theme.textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.privacyIntro, style: theme.textTheme.bodyMedium),
                      const SizedBox(height: 12),
                      Text(
                        l10n.privacyBullets,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              FilledButton(
                onPressed: () => _agree(context, ref),
                child: Text(l10n.privacyAgree),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => _openFullPolicy(context),
                child: Text(l10n.privacyFullPolicy),
              ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: () => _decline(context),
                child: Text(
                  l10n.privacyDecline,
                  style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _agree(BuildContext context, WidgetRef ref) async {
    // 记录同意时间（可追溯，CN 合规要求）。
    await ref.read(settingsProvider.notifier).agreePrivacy();
    if (context.mounted) context.go('/onboarding/mode');
  }

  Future<void> _openFullPolicy(BuildContext context) async {
    final uri = Uri.tryParse(Brand.privacyUrl);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _decline(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.privacyDeclined)),
    );
  }
}
