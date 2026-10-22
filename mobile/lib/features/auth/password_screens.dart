import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/session.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/theme.dart';
import '../../shared/widgets/common.dart';

class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  ConsumerState<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen> {
  final _email = TextEditingController();
  bool _busy = false;
  bool _sent = false;
  String? _devToken;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _busy = true);
    try {
      final res = await ref.read(apiProvider).post('/auth/password/forgot', {'email': _email.text.trim()}) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _sent = true;
        _devToken = res['dev_token'] as String?;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(context.t('forgot.title'))),
      body: PageList(width: 440, children: [
        if (!_sent) ...[
          Text(context.t('forgot.body'), style: theme.textTheme.bodyMedium),
          const SizedBox(height: 16),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            decoration: InputDecoration(labelText: context.t('field.email'), prefixIcon: const Icon(Icons.mail_outline)),
            onSubmitted: (_) => _send(),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _busy ? null : _send, child: Text(context.t('forgot.send'))),
        ] else ...[
          const Icon(Icons.mark_email_read_outlined, size: 56, color: Brand.success),
          const SizedBox(height: 12),
          Text(context.t('forgot.sent'), style: theme.textTheme.bodyLarge, textAlign: TextAlign.center),
          if (_devToken != null) ...[
            const SizedBox(height: 16),
            OutlinedButton(
                onPressed: () => context.go('/reset?token=$_devToken'), child: Text(context.t('forgot.dev_open'))),
          ],
        ],
      ]),
    );
  }
}

class ResetPasswordScreen extends ConsumerStatefulWidget {
  final String token;
  const ResetPasswordScreen({super.key, required this.token});

  @override
  ConsumerState<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> {
  final _password = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _reset() async {
    setState(() => _busy = true);
    try {
      await ref.read(apiProvider).post('/auth/password/reset', {'token': widget.token, 'password': _password.text});
      if (!mounted) return;
      showInfo(context, context.t('reset.done'));
      context.go('/login');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.t('reset.title'))),
      body: PageList(width: 440, children: [
        TextField(
          controller: _password,
          obscureText: true,
          decoration: InputDecoration(
              labelText: context.t('reset.new_password'),
              helperText: context.t('register.password_help'),
              prefixIcon: const Icon(Icons.lock_outline)),
          onSubmitted: (_) => _reset(),
        ),
        const SizedBox(height: 16),
        FilledButton(onPressed: _busy || widget.token.isEmpty ? null : _reset, child: Text(context.t('reset.submit'))),
      ]),
    );
  }
}
