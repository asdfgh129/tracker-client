import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/config/brand.dart';
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

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _tokenController.dispose();
    super.dispose();
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

  Future<void> _submit() async {
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
            );
      }
      // 登录成功 → 主界面（async gap 后必须查 mounted）。
      if (mounted) context.go('/map');
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

  Future<void> _goOffline() async {
    // 离线只读：不登录直接进主界面（缓存数据可见，顶部离线横幅）。
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
