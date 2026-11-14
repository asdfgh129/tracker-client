import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/location/vendor_hints.dart';
import '../../../core/observability/logger.dart';
import '../../../l10n/app_localizations.dart';
import '../../auth/application/session_controller.dart';
import '../application/settings_controller.dart';

/// 设置页（SET-01～SET-06、CN-07/09，docs/02 §1 我的）。
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final settings = ref.watch(settingsProvider);
    final session = ref.watch(sessionControllerProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: ListView(
        children: [
          // 账号。
          _SectionHeader(l10n.settingsAccount),
          if (session?.user case final user?)
            ListTile(
              leading: const Icon(Icons.account_circle_outlined),
              title: Text(user.name),
              subtitle: Text(user.email),
            ),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: Text(l10n.settingsServer),
            subtitle: Text(session?.profile?.apiBaseUrl ?? '-'),
            onTap: () => context.push('/server'),
          ),
          ListTile(
            leading: const Icon(Icons.logout),
            title: Text(l10n.settingsLogout),
            onTap: () => _logout(context, ref),
          ),
          const Divider(),

          // 通用。
          _SectionHeader(l10n.settingsMap),
          ListTile(
            leading: const Icon(Icons.map_outlined),
            title: Text(l10n.settingsMapStyle),
            trailing: SegmentedButton<MapStylePref>(
              segments: [
                ButtonSegment(
                    value: MapStylePref.standard,
                    icon: const Icon(Icons.public)),
                ButtonSegment(
                    value: MapStylePref.satellite,
                    icon: const Icon(Icons.satellite_alt)),
                ButtonSegment(
                    value: MapStylePref.night,
                    icon: const Icon(Icons.dark_mode)),
              ],
              selected: {settings.mapStyle},
              onSelectionChanged: (selection) => ref
                  .read(settingsProvider.notifier)
                  .setMapStyle(selection.first),
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.timeline),
            title: Text(l10n.settingsMapTrail),
            value: settings.mapTrail,
            onChanged: (value) =>
                ref.read(settingsProvider.notifier).setMapTrail(value),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.scatter_plot_outlined),
            title: Text(l10n.settingsMapCluster),
            value: settings.mapCluster,
            onChanged: (value) =>
                ref.read(settingsProvider.notifier).setMapCluster(value),
          ),
          const Divider(),

          _SectionHeader(l10n.settingsTheme),
          ListTile(
            leading: const Icon(Icons.brightness_6_outlined),
            title: Text(l10n.settingsTheme),
            trailing: SegmentedButton<ThemeMode>(
              segments: [
                ButtonSegment(value: ThemeMode.system, label: Text(l10n.themeSystem)),
                ButtonSegment(value: ThemeMode.light, label: Text(l10n.themeLight)),
                ButtonSegment(value: ThemeMode.dark, label: Text(l10n.themeDark)),
              ],
              selected: {settings.themeMode},
              onSelectionChanged: (selection) => ref
                  .read(settingsProvider.notifier)
                  .setThemeMode(selection.first),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.language),
            title: Text(l10n.settingsLanguage),
            trailing: DropdownButton<String?>(
              value: settings.localeLanguageCode,
              underline: const SizedBox.shrink(),
              items: [
                DropdownMenuItem(
                  child: Text(l10n.languageSystem),
                ),
                const DropdownMenuItem(value: 'en', child: Text('English')),
                const DropdownMenuItem(value: 'zh', child: Text('中文')),
              ],
              onChanged: (value) => ref
                  .read(settingsProvider.notifier)
                  .setLocale(value),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.square_foot),
            title: Text(l10n.settingsUnits),
            trailing: SegmentedButton<UnitSystem>(
              segments: [
                ButtonSegment(value: UnitSystem.metric, label: Text(l10n.unitsMetric)),
                ButtonSegment(
                    value: UnitSystem.imperial, label: Text(l10n.unitsImperial)),
              ],
              selected: {settings.units},
              onSelectionChanged: (selection) =>
                  ref.read(settingsProvider.notifier).setUnits(selection.first),
            ),
          ),
          const Divider(),

          // 隐私（CN-07）。
          _SectionHeader(l10n.settingsPrivacy),
          ExpansionTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: Text(l10n.settingsPrivacyList),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Text(
                  l10n.settingsPrivacyListBody,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
          ExpansionTile(
            leading: const Icon(Icons.extension_outlined),
            title: Text(l10n.settingsSdkList),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Text(
                  l10n.settingsSdkListBody,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
          SwitchListTile(
            secondary: const Icon(Icons.analytics_outlined),
            title: Text(l10n.settingsAnalytics),
            subtitle: Text(l10n.settingsAnalyticsDesc),
            value: settings.analyticsEnabled,
            onChanged: (value) => ref
                .read(settingsProvider.notifier)
                .setAnalyticsEnabled(value),
          ),
          ListTile(
            leading: const Icon(Icons.tune),
            title: Text(l10n.permWizardTitle),
            subtitle: const VendorMiniHint(),
            onTap: () => context.push('/onboarding/permissions'),
          ),
          ListTile(
            leading: const Icon(Icons.delete_sweep_outlined),
            title: Text(l10n.settingsDeleteData),
            onTap: () => _wipeData(context, ref),
          ),
          // CN：撤回同意入口（撤回后停止一切第三方采集并清本地数据）。
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: Text(l10n.settingsRevokePrivacy),
            subtitle: Text(l10n.settingsRevokePrivacyDesc),
            onTap: () => _revokePrivacy(context, ref),
          ),
          const Divider(),

          _SectionHeader(l10n.commonDone),
          ListTile(
            leading: const Icon(Icons.notifications_active_outlined),
            title: Text(l10n.settingsNotifications),
            subtitle: Text(l10n.settingsNotificationsDesc),
            onTap: () => context.push('/settings/notifications'),
          ),
          ListTile(
            leading: const Icon(Icons.monitor_heart_outlined),
            title: Text(l10n.settingsDiagnostics),
            onTap: () => context.push('/diagnostics'),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(l10n.settingsAbout),
            onTap: () => context.push('/settings/about'),
          ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: Text(l10n.aboutLicenses),
            onTap: () => showLicensePage(context: context),
          ),
        ],
      ),
    );
  }

  Future<void> _logout(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(l10n.settingsLogoutConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.settingsLogout),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await ref.read(sessionControllerProvider.notifier).logout();
      AppLog.i('auth', 'logout');
    }
  }

  /// 撤回隐私同意（PIPL 要求可撤回）：停采集 + 清本地数据。
  Future<void> _revokePrivacy(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.settingsRevokePrivacy),
        content: Text(l10n.settingsRevokePrivacyConfirm),
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
    if (confirmed ?? false) {
      await ref.read(settingsProvider.notifier).revokePrivacy();
    }
  }

  Future<void> _wipeData(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(l10n.settingsDeleteDataConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await ref.read(settingsProvider.notifier).wipeLocalData();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.settingsDeleteDataDone)),
        );
      }
    }
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

/// 厂商引导迷你提示。
class VendorMiniHint extends StatelessWidget {
  const VendorMiniHint({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Text(
      VendorHintsResolver.localize(
        l10n,
        VendorHintsResolver.detectFromPlatform(),
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
