import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_client.dart';
import '../../core/auth/session.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/theme.dart';
import '../../shared/widgets/brand.dart';
import '../../shared/widgets/common.dart';

const demoPassword = 'demo1234';
const demoAccounts = [
  ('demo.borrower', 'borrower1@demo.app', Icons.person_outline),
  ('demo.officer', 'mahmud@greenfield.demo', Icons.badge_outlined),
  ('demo.admin', 'admin@greenfield.demo', Icons.admin_panel_settings_outlined),
  ('demo.owner', 'super@lenden.app', Icons.hub_outlined),
];

/// Sign in with email + password (staff may be asked for a 2FA code) or with a mobile number + code.
class LoginScreen extends ConsumerStatefulWidget {
  final String? from;
  const LoginScreen({super.key, this.from});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _totp = TextEditingController();
  final _phone = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false;
  bool _needTotp = false;
  bool _codeSent = false;
  bool _hide = true;
  bool _usePhone = false;

  @override
  void dispose() {
    for (final c in [_email, _password, _totp, _phone, _code]) {
      c.dispose();
    }
    super.dispose();
  }

  void _done() {
    final s = ref.read(sessionProvider);
    final from = widget.from;
    context.go(from != null && from.startsWith('/') && s.isBorrower ? from : s.homePath);
  }

  Future<void> _login() async {
    setState(() => _busy = true);
    try {
      await ref.read(sessionProvider.notifier).login(_email.text, _password.text, totp: _needTotp ? _totp.text : null);
      if (mounted) _done();
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == 'TOTP_REQUIRED') {
        setState(() => _needTotp = true);
      } else {
        showError(context, e);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendCode() async {
    setState(() => _busy = true);
    try {
      final res = await ref.read(sessionProvider.notifier).requestOtp(_phone.text);
      if (!mounted) return;
      setState(() => _codeSent = true);
      final dev = res['dev_code'];
      showInfo(context, dev == null ? context.t('login.code_sent') : context.t('login.dev_code', {'code': dev}));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verifyCode() async {
    setState(() => _busy = true);
    try {
      await ref.read(sessionProvider.notifier).loginWithOtp(_phone.text, _code.text);
      if (mounted) _done();
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
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => context.go('/')),
        actions: [
          IconButton(
              tooltip: context.t('server.title'), icon: const Icon(Icons.dns_outlined), onPressed: () => context.push('/server')),
          const Padding(padding: EdgeInsets.only(right: 12), child: LanguageToggle()),
        ],
      ),
      body: PageList(width: 440, children: [
        const Center(child: AppLogo(size: 44)),
        const SizedBox(height: 20),
        Text(context.t('login.title'), style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
        const SizedBox(height: 4),
        Text(context.t('login.subtitle'),
            style: theme.textTheme.bodyMedium?.copyWith(color: Brand.muted), textAlign: TextAlign.center),
        const SizedBox(height: 20),
        SegmentedButton<bool>(
          segments: [
            ButtonSegment(value: false, icon: const Icon(Icons.mail_outline), label: Text(context.t('login.email_tab'))),
            ButtonSegment(value: true, icon: const Icon(Icons.phone_iphone), label: Text(context.t('login.phone_tab'))),
          ],
          selected: {_usePhone},
          onSelectionChanged: (s) => setState(() => _usePhone = s.first),
        ),
        const SizedBox(height: 16),
        if (!_usePhone) ...[
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            decoration: InputDecoration(labelText: context.t('field.email'), prefixIcon: const Icon(Icons.mail_outline)),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: _hide,
            autofillHints: const [AutofillHints.password],
            onSubmitted: (_) => _login(),
            decoration: InputDecoration(
              labelText: context.t('field.password'),
              prefixIcon: const Icon(Icons.lock_outline),
              suffixIcon: IconButton(
                  icon: Icon(_hide ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _hide = !_hide)),
            ),
          ),
          if (_needTotp) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _totp,
              autofocus: true,
              keyboardType: TextInputType.number,
              onSubmitted: (_) => _login(),
              decoration: InputDecoration(
                  labelText: context.t('login.totp'), helperText: context.t('login.totp_help'), prefixIcon: const Icon(Icons.pin_outlined)),
            ),
          ],
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: () => context.push('/forgot'), child: Text(context.t('login.forgot'))),
          ),
          FilledButton(
            onPressed: _busy ? null : _login,
            child: _busy
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(context.t('login.submit')),
          ),
        ] else ...[
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(
                labelText: context.t('field.phone'), hintText: '01712345678', prefixIcon: const Icon(Icons.phone_iphone)),
          ),
          if (_codeSent) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _code,
              keyboardType: TextInputType.number,
              autofocus: true,
              onSubmitted: (_) => _verifyCode(),
              decoration: InputDecoration(labelText: context.t('login.code'), prefixIcon: const Icon(Icons.sms_outlined)),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : (_codeSent ? _verifyCode : _sendCode),
            child: Text(_codeSent ? context.t('login.verify') : context.t('login.send_code')),
          ),
          if (_codeSent)
            TextButton(onPressed: _busy ? null : _sendCode, child: Text(context.t('login.resend'))),
          const SizedBox(height: 4),
          Text(context.t('login.phone_note'), style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
        ],
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(context.t('login.no_account')),
          TextButton(
              onPressed: () => context.go(widget.from == null ? '/register' : '/register?from=${widget.from}'),
              child: Text(context.t('login.create'))),
        ]),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(context.t('login.demo_title'), style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(context.t('login.demo_sub', {'password': demoPassword}), style: theme.textTheme.bodySmall),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final (label, email, icon) in demoAccounts)
                  ActionChip(
                    avatar: Icon(icon, size: 18),
                    label: Text(context.t(label)),
                    onPressed: () => setState(() {
                      _usePhone = false;
                      _email.text = email;
                      _password.text = demoPassword;
                    }),
                  ),
              ]),
            ]),
          ),
        ),
      ]),
    );
  }
}
