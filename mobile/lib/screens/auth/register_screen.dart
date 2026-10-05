import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../widgets/common.dart';

class RegisterScreen extends StatefulWidget {
  final bool returnOnSuccess;

  const RegisterScreen({super.key, this.returnOnSuccess = false});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await AppScope.read(context).register(_name.text.trim(), _email.text.trim(), _password.text);
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
      appBar: AppBar(title: const Text('Create account')),
      body: MaxWidth(
        width: 460,
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text('Borrower account', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text('Lender staff accounts are created by their organisation admin.',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 16),
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Full name', border: OutlineInputBorder()),
                validator: (v) => (v ?? '').trim().length < 2 ? 'Enter your name' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder()),
                validator: (v) => (v ?? '').contains('@') ? null : 'Enter a valid email',
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(
                    labelText: 'Password (8+ characters)', border: OutlineInputBorder()),
                validator: (v) => (v ?? '').length < 8 ? 'At least 8 characters' : null,
              ),
              const SizedBox(height: 16),
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Create account'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
