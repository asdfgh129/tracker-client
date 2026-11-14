import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../app/theme.dart';
import '../../../core/network/server_profile.dart';
import '../../../core/storage/database.dart';
import '../../../l10n/app_localizations.dart';
import '../../auth/application/session_controller.dart';
import '../application/server_profile_controller.dart';

/// 服务器档案页（AUTH-01/02/03/11，docs/02 §3.2）。
class ServerSetupScreen extends ConsumerStatefulWidget {
  const ServerSetupScreen({super.key});

  @override
  ConsumerState<ServerSetupScreen> createState() => _ServerSetupScreenState();
}

class _ServerSetupScreenState extends ConsumerState<ServerSetupScreen> {
  final _nameController = TextEditingController();
  final _addressController = TextEditingController();
  final _apiController = TextEditingController();
  final _reportController = TextEditingController();

  bool _advanced = false;
  bool _allowSelfSigned = false;
  bool _allowInsecure = false;
  bool _manualUrls = false;
  ProbeResult? _probe;
  bool _probing = false;
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    _apiController.dispose();
    _reportController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(serverProfileControllerProvider);
    final profiles = state.valueOrNull?.profiles ?? const [];

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.serverTitle),
        actions: [
          IconButton(
            tooltip: l10n.serverScanQr,
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: () => _openScanner(l10n),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (profiles.isNotEmpty) ...[
            _ProfileList(profiles: profiles),
            const SizedBox(height: 16),
            Text(l10n.serverTitle, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
          ],
          TextField(
            controller: _nameController,
            decoration: InputDecoration(labelText: l10n.serverName),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _addressController,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: l10n.serverAddress,
              hintText: l10n.serverAddressHint,
              helperText: l10n.serverAddressHelp,
            ),
            onChanged: (_) => setState(() => _probe = null),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => setState(() => _advanced = !_advanced),
            child: Text(
              _advanced ? l10n.commonClose : l10n.serverAdvanced,
            ),
          ),
          if (_advanced) ...[
            CheckboxListTile(
              value: _manualUrls,
              onChanged: (value) => setState(() => _manualUrls = value ?? false),
              title: Text(l10n.serverAdvanced),
            ),
            if (_manualUrls) ...[
              TextField(
                controller: _apiController,
                decoration:
                    InputDecoration(labelText: l10n.serverApiUrl),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _reportController,
                decoration:
                    InputDecoration(labelText: l10n.serverReportUrl),
              ),
            ],
            CheckboxListTile(
              value: _allowSelfSigned,
              onChanged: (value) =>
                  setState(() => _allowSelfSigned = value ?? false),
              title: Text(l10n.serverAllowSelfSigned),
              subtitle: Text(
                l10n.serverAllowSelfSignedWarn,
                style: TextStyle(color: theme.colorScheme.statusWarning),
              ),
              controlAffinity: ListTileControlAffinity.leading,
            ),
            // H-3：明文 HTTP 与自签名证书是两件独立的事，必须单独确认。
            // 行踪轨迹属敏感个人信息，明文传输不符合 PIPL 加密要求。
            CheckboxListTile(
              value: _allowInsecure,
              onChanged: (value) async {
                if (value ?? false) {
                  final confirmed = await _confirmInsecure(l10n);
                  if (!confirmed) return;
                }
                setState(() => _allowInsecure = value ?? false);
              },
              title: Text(l10n.serverAllowInsecure),
              subtitle: Text(
                l10n.serverAllowInsecureWarn,
                style: TextStyle(color: theme.colorScheme.statusWarning),
              ),
              controlAffinity: ListTileControlAffinity.leading,
            ),
          ],
          const SizedBox(height: 16),
          if (_probe != null) _ProbeResultCard(result: _probe!),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _probing ? null : _test,
                  child: Text(l10n.serverTest),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _saving ? null : _saveAndContinue,
                  child: Text(l10n.serverSaveContinue),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// H-3：手工填写的 API / 上报地址同样要过 scheme / host 校验；
  /// 明文 HTTP 必须由独立的 [_allowInsecure] 开关显式放行
  ///（不再借用「自签名证书」勾选项 —— 那是两件不同的事）。
  ServerProfile _currentProfile() {
    final name = _nameController.text.trim();
    if (_manualUrls &&
        _apiController.text.trim().isNotEmpty &&
        _reportController.text.trim().isNotEmpty) {
      final api = ServerAddressDeriver.validateManualUrl(
        _apiController.text,
        allowInsecure: _allowInsecure,
      );
      final report = ServerAddressDeriver.validateManualUrl(
        _reportController.text,
        allowInsecure: _allowInsecure,
      );
      return ServerProfile(
        name: name.isEmpty ? (Uri.tryParse(api)?.host ?? '') : name,
        apiBaseUrl: api,
        reportUrl: report,
        allowSelfSigned: _allowSelfSigned,
        allowInsecure: _allowInsecure,
      );
    }
    return ServerAddressDeriver.derive(
      input: _addressController.text,
      name: name.isEmpty ? null : name,
      allowSelfSigned: _allowSelfSigned,
      allowInsecure: _allowInsecure,
    );
  }

  /// 明文 HTTP 二次确认：位置、账号与 Token 未加密传输，需显式知情。
  Future<bool> _confirmInsecure(AppLocalizations l10n) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.serverAllowInsecure),
        content: Text(l10n.serverAllowInsecureWarn),
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

  Future<void> _test() async {
    setState(() {
      _probing = true;
      _probe = null;
    });
    try {
      final profile = _currentProfile();
      final result = await ref
          .read(serverProfileControllerProvider.notifier)
          .probe(profile);
      setState(() => _probe = result);
    } on ServerAddressException catch (error) {
      setState(() {
        _probe = ProbeResult(
          outcome: ProbeOutcome.notTraccar,
          detail: error.message,
        );
      });
    } finally {
      setState(() => _probing = false);
    }
  }

  Future<void> _saveAndContinue() async {
    try {
      final profile = _currentProfile();
      setState(() => _saving = true);
      await ref
          .read(serverProfileControllerProvider.notifier)
          .saveProfile(profile);
      if (!mounted) return;
      // 已有会话（多服务器切换）→ 直接进主界面；否则登录。
      final session = ref.read(sessionControllerProvider).value;
      if (session?.isAuthenticated ?? false) {
        context.go('/map');
      } else {
        context.go('/login');
      }
    } on ServerAddressException catch (error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openScanner(AppLocalizations l10n) async {
    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _QrScannerPage()),
    );
    if (code == null || !mounted) return;
    try {
      final parsed = ServerAddressDeriver.parseImport(code);
      _nameController.text = parsed.profile.name;
      _addressController.text = parsed.profile.apiBaseUrl;
      setState(() {
        _advanced = true;
        _manualUrls = true;
        _apiController.text = parsed.profile.apiBaseUrl;
        _reportController.text = parsed.profile.reportUrl;
      });
    } on ServerAddressException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.serverQrInvalid(error.message))),
        );
      }
    }
  }
}

class _ProfileList extends ConsumerWidget {
  const _ProfileList({required this.profiles});

  final List<ServerProfileRow> profiles;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.serverSwitch, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final profile in profiles)
          Card(
            child: ListTile(
              leading: Icon(
                Icons.dns_outlined,
                color: profile.isActive
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              title: Text(profile.name),
              subtitle: Text(profile.apiBaseUrl),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (profile.isDemo)
                    Chip(
                      label: Text(l10n.serverDemoBadge),
                      visualDensity: VisualDensity.compact,
                    ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          content: Text(l10n.serverDeleteConfirm),
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
                        await ref
                            .read(serverProfileControllerProvider.notifier)
                            .deleteProfile(profile.id);
                      }
                    },
                  ),
                ],
              ),
              onTap: () async {
                await ref
                    .read(serverProfileControllerProvider.notifier)
                    .activate(profile.id);
                if (context.mounted) context.go('/login');
              },
            ),
          ),
      ],
    );
  }
}

class _ProbeResultCard extends StatelessWidget {
  const _ProbeResultCard({required this.result});

  final ProbeResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    final (icon, color, text) = switch (result.outcome) {
      ProbeOutcome.ok => (
          Icons.check_circle_outline,
          theme.colorScheme.statusOnline,
          l10n.serverProbeOk(
            result.serverName ?? '-',
            result.version ?? '-',
            result.latencyMs ?? 0,
          ),
        ),
      ProbeOutcome.reachableNeedsAuth => (
          Icons.info_outline,
          theme.colorScheme.statusWarning,
          l10n.serverProbeNeedsAuth,
        ),
      ProbeOutcome.timeout => (
          Icons.timer_off_outlined,
          theme.colorScheme.statusDanger,
          l10n.serverProbeTimeout,
        ),
      ProbeOutcome.tls => (
          Icons.gpp_bad_outlined,
          theme.colorScheme.statusDanger,
          l10n.serverProbeTls,
        ),
      ProbeOutcome.notTraccar => (
          Icons.help_outline,
          theme.colorScheme.statusDanger,
          result.detail ?? l10n.serverProbeNotTraccar,
        ),
      ProbeOutcome.networkError => (
          Icons.cloud_off_outlined,
          theme.colorScheme.statusDanger,
          l10n.serverProbeError(result.detail ?? '-'),
        ),
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 12),
            Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
          ],
        ),
      ),
    );
  }
}

class _QrScannerPage extends StatefulWidget {
  const _QrScannerPage();

  @override
  State<_QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<_QrScannerPage> {
  MobileScannerController? _controller;
  bool _done = false;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    _controller ??= MobileScannerController();
    return Scaffold(
      appBar: AppBar(title: Text(l10n.serverScanQr)),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller!,
            onDetect: (capture) {
              if (_done) return;
              final barcode = capture.barcodes.firstOrNull;
              final value = barcode?.rawValue;
              if (value != null && value.isNotEmpty) {
                _done = true;
                Navigator.of(context).pop(value);
              }
            },
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 48,
            child: Text(
              l10n.serverScanHint,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
