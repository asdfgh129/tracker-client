import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/config/brand.dart';
import '../../../l10n/app_localizations.dart';
import '../../auth/application/session_controller.dart';

/// 关于页（SET-06、CN-08：APP 备案号、地图审图号、隐私政策）。
///
/// 备案号与审图号为占位值（`Brand` / `--dart-define` 注入），
/// 上线前替换为真实值。
class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final session = ref.watch(sessionControllerProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.aboutTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (context, snapshot) => ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(l10n.aboutVersion(snapshot.data?.version ?? '-')),
            ),
          ),
          // APP 备案号（CN-08，占位：上线前由品牌配置注入真实值）。
          ListTile(
            leading: const Icon(Icons.verified_outlined),
            title: Text(l10n.aboutIcp),
            subtitle: Text(
              Brand.appFilingNumber.isEmpty
                  ? l10n.aboutIcpPlaceholder
                  : Brand.appFilingNumber,
            ),
          ),
          // 地图审图号（CN-08）。
          ListTile(
            leading: const Icon(Icons.map_outlined),
            title: Text(
              Brand.mapApprovalNumber.isEmpty
                  ? l10n.aboutMapLicensePending
                  : l10n.aboutMapLicense(Brand.mapApprovalNumber),
            ),
          ),
          if (session?.serverVersion case final version?)
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: Text(l10n.aboutServerVersion(version)),
            ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: Text(l10n.aboutPrivacyPolicy),
            onTap: () async {
              final uri = Uri.tryParse(Brand.privacyUrl);
              if (uri != null) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.support_agent),
            title: Text(l10n.aboutSupport),
            onTap: () async {
              final uri = Uri.tryParse(Brand.supportUrl);
              if (uri != null) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: Text(l10n.aboutLicenses),
            onTap: () => showLicensePage(context: context),
          ),
          const SizedBox(height: 24),
          Text(
            Brand.appName,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
