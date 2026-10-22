import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/session.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/theme.dart';
import '../../shared/widgets/brand.dart';
import '../../shared/widgets/common.dart';

/// Create a borrower account. Asked only when the borrower wants to save or apply, so the
/// answers given so far carry over (the anonymous draft is claimed on sign-up).
class RegisterScreen extends ConsumerStatefulWidget {
  final String? from;
  const RegisterScreen({super.key, this.from});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _hide = true;

  @override
  void dispose() {
    for (final c in [_name, _email, _phone, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() => _busy = true);
    try {
      await ref.read(sessionProvider.notifier).register(_name.text, _email.text, _password.text,
          phone: _phone.text, locale: ref.read(localeProvider).languageCode);
      if (!mounted) return;
      final from = widget.from;
      context.go(from != null && from.startsWith('/') ? from : '/home');
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
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => context.canPop() ? context.pop() : context.go('/')),
        actions: const [Padding(padding: EdgeInsets.only(right: 12), child: LanguageToggle())],
      ),
      body: Form(
        key: _form,
        child: PageList(width: 440, children: [
          const Center(child: AppLogo(size: 44)),
          const SizedBox(height: 20),
          Text(context.t('register.title'), style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
          const SizedBox(height: 4),
          Text(widget.from == '/offers' ? context.t('register.subtitle_offers') : context.t('register.subtitle'),
              style: theme.textTheme.bodyMedium?.copyWith(color: Brand.muted), textAlign: TextAlign.center),
          const SizedBox(height: 20),
          TextFormField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            autofillHints: const [AutofillHints.name],
            decoration: InputDecoration(labelText: context.t('field.name'), prefixIcon: const Icon(Icons.person_outline)),
            validator: (v) => (v ?? '').trim().length < 2 ? context.t('error.NAME_REQUIRED') : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            decoration: InputDecoration(labelText: context.t('field.email'), prefixIcon: const Icon(Icons.mail_outline)),
            validator: (v) => (v ?? '').contains('@') ? null : context.t('error.EMAIL_INVALID'),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(
                labelText: context.t('field.phone_optional'),
                hintText: '01712345678',
                helperText: context.t('register.phone_help'),
                prefixIcon: const Icon(Icons.phone_iphone)),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _password,
            obscureText: _hide,
            autofillHints: const [AutofillHints.newPassword],
            decoration: InputDecoration(
              labelText: context.t('field.password'),
              helperText: context.t('register.password_help'),
              prefixIcon: const Icon(Icons.lock_outline),
              suffixIcon: IconButton(
                  icon: Icon(_hide ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _hide = !_hide)),
            ),
            validator: (v) => (v ?? '').length < 8 ? context.t('error.PASSWORD_SHORT') : null,
            onFieldSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(context.t('register.submit')),
          ),
          const SizedBox(height: 8),
          Text(context.t('register.terms'), style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(context.t('register.have_account')),
            TextButton(
                onPressed: () => context.go(widget.from == null ? '/login' : '/login?from=${widget.from}'),
                child: Text(context.t('login.submit'))),
          ]),
        ]),
      ),
    );
  }
}
