import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/config/brand.dart';
import '../../../core/network/traccar_api.dart';
import '../../../core/observability/logger.dart';
import '../../../core/storage/preferences.dart';
import '../../../domain/failures.dart';
import '../../../l10n/app_localizations.dart';
import '../application/session_controller.dart';

/// 登录页（AUTH-04/05/06，docs/02 §3.3）。
///
/// 错误内联提示，不禁用整个页面；断网可离线只读进入。
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _tokenController = TextEditingController();
  bool _remember = false;
  bool _tokenMode = false;
  bool _busy = false;
  String? _error;

  /// 服务端 OIDC 能力（GET /api/server 探测 + Prefs 缓存）。
  bool? _openIdEnabled;
  bool? _openIdForce;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _probeOpenId());
  }

  /// 探测服务端 OIDC 能力（PermitAll）；先读缓存立即显隐，再刷新。
  Future<void> _probeOpenId() async {
    final profile = ref.read(sessionControllerProvider).valueOrNull?.profile;
    if (profile == null) return;
    final prefs = ref.read(prefsProvider);
    if (mounted) {
      setState(() {
        _openIdEnabled = prefs.getBool(PrefKeys.serverOpenIdEnabled);
        _openIdForce = prefs.getBool(PrefKeys.serverOpenIdForce);
      });
    }
    try {
      final server = await TraccarApi(profile: profile).getServer();
      final enabled = ServerInfo.openIdEnabledOf(server);
      final force = ServerInfo.openIdForceOf(server);
      if (enabled != null) await prefs.setBool(PrefKeys.serverOpenIdEnabled, enabled);
      if (force != null) await prefs.setBool(PrefKeys.serverOpenIdForce, force);
      if (mounted) {
        setState(() {
          _openIdEnabled = enabled ?? _openIdEnabled;
          _openIdForce = force ?? _openIdForce;
        });
      }
    } on Object catch (error) {
      AppLog.w('auth', 'openid probe failed: $error');
    }
  }

  /// 跳系统浏览器完成 IdP 授权；回跳经深链交 [SessionController]。
  Future<void> _startOpenIdLogin() async {
    final profile = ref.read(sessionControllerProvider).valueOrNull?.profile;
    if (profile == null || profile.apiBaseUrl.isEmpty) return;
    setState(() => _error = null);
    try {
      await launchUrl(
        buildOpenIdAuthUrl(profile.apiBaseUrl),
        mode: LaunchMode.externalApplication,
      );
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final profile = ref.watch(sessionControllerProvider).valueOrNull?.profile;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.loginTitle),
        actions: [
          if (profile != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Text(
                  profile.name,
                  style: theme.textTheme.labelLarge
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ),
        ],
      ),
      body: AutofillGroup(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (!_tokenMode) ...[
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                decoration: InputDecoration(labelText: l10n.loginEmail),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passwordController,
                obscureText: true,
                autofillHints: const [AutofillHints.password],
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(labelText: l10n.loginPassword),
              ),
              CheckboxListTile(
                value: _remember,
                onChanged: (value) => setState(() => _remember = value ?? false),
                title: Text(l10n.loginRemember),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
            ] else ...[
              TextField(
                controller: _tokenController,
                obscureText: true,
                autocorrect: false,
                maxLines: 3,
                minLines: 1,
                decoration: InputDecoration(
                  labelText: l10n.loginToken,
                  helperText: l10n.loginTokenHint,
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(l10n.loginButton),
            ),
            // OIDC 企业登录（0.5.0）：服务端 openIdEnabled 时显示；
            // openIdForce 时提示密码登录不可用（服务端会拒绝表单登录）。
            if (_openIdEnabled ?? false) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy ? null : _startOpenIdLogin,
                icon: const Icon(Icons.business_center_outlined),
                label: Text(l10n.loginWithOpenId),
              ),
              if (_openIdForce ?? false)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    l10n.loginOpenIdForceHint,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
            ],
            TextButton(
              onPressed: () => setState(() {
                _tokenMode = !_tokenMode;
                _error = null;
              }),
              child: Text(_tokenMode ? l10n.loginEmail : l10n.loginWithToken),
            ),
            TextButton(
              onPressed: _openForgot,
              child: Text(l10n.loginForgot),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _busy ? null : _goOffline,
              child: Text(
                l10n.loginOfflineMode,
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _submit({String? totpCode}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_tokenMode) {
        final token = _tokenController.text.trim();
        if (token.isEmpty) {
          setState(() => _error = 'Token is empty');
          return;
        }
        await ref.read(sessionControllerProvider.notifier).loginWithToken(token);
      } else {
        await ref.read(sessionControllerProvider.notifier).loginWithPassword(
              email: _emailController.text.trim(),
              password: _passwordController.text,
              rememberPassword: _remember,
              totpCode: totpCode,
            );
      }
      // 登录成功 → 主界面（async gap 后必须查 mounted）。
      if (mounted) context.go('/map');
    } on TotpRequiredFailure {
      // 服务端要求两步验证：弹码输入后携带 code 重试（docs/04 §2.1）。
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      final code = await _promptTotpCode(l10n);
      if (!mounted) return;
      if (code == null || code.isEmpty) {
        setState(() => _error = l10n.loginTotpCancelled);
        return;
      }
      return _submit(totpCode: code);
    } on AppFailure catch (error) {
      // async gap 后先用 mounted 守卫，再取 context 派生文案。
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      setState(() {
        _error = switch (error) {
          UnauthorizedFailure() => l10n.loginFailed,
          _ => error.userMessage,
        };
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 两步验证码输入对话框；取消/清空返回 null。
  Future<String?> _promptTotpCode(AppLocalizations l10n) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.loginTotpTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          maxLength: 8,
          decoration: InputDecoration(hintText: l10n.loginTotpHint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: Text(l10n.loginTotpSubmit),
          ),
        ],
      ),
    );
  }

  Future<void> _goOffline() async {
    // 离线只读：不登录直接进主界面（缓存数据可见，顶部离线横幅）。
    ref.read(sessionControllerProvider.notifier).enterReadOnly();
    if (mounted) context.go('/map');
  }

  Future<void> _openForgot() async {
    final profile = ref.read(sessionControllerProvider).valueOrNull?.profile;
    final base = profile?.apiBaseUrl ?? Brand.demoServerUrl;
    final uri = Uri.tryParse('$base/#/login');
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
