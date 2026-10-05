import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../widgets/brand.dart';
import '../../widgets/common.dart';
import 'register_screen.dart';

/// Demo accounts (password demo1234) so reviewers can try every role in one tap.
const demoAccounts = <String, String>{
  'Borrower': 'borrower1@demo.app',
  'Loan officer': 'mahmud@greenfield.demo',
  'Lender admin': 'admin@greenfield.demo',
  'Platform owner': 'super@lenden.app',
};

class LoginScreen extends StatefulWidget {
  /// When true, just close this screen after login (e.g. mid-way through applying).
  final bool returnOnSuccess;

  const LoginScreen({super.key, this.returnOnSuccess = false});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _hide = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      await AppScope.read(context).login(_email.text.trim(), _password.text);
      if (!mounted) return;
      final nav = Navigator.of(context);
      if (widget.returnOnSuccess) {
        nav.pop(true);
      } else {
        nav.popUntil((route) => route.isFirst);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: MaxWidth(
        width: 460,
        child: AutofillGroup(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Center(child: AppLogo(size: 44)),
              const SizedBox(height: 20),
              Text('Welcome back', textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 4),
              Text('Borrowers, loan officers and lender admins all sign in here.',
                  textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 24),
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                obscureText: _hide,
                autofillHints: const [AutofillHints.password],
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: 'Password',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(_hide ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => _hide = !_hide),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('login-submit'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Log in'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
                    builder: (_) => RegisterScreen(returnOnSuccess: widget.returnOnSuccess))),
                child: const Text('No account? Create one'),
              ),
              const SizedBox(height: 24),
              Text('Try a demo account', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final e in demoAccounts.entries)
                    ActionChip(
                      label: Text(e.key),
                      onPressed: () {
                        _email.text = e.value;
                        _password.text = 'demo1234';
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
