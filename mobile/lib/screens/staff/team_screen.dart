import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../widgets/account_menu.dart';
import '../../widgets/common.dart';

class TeamScreen extends StatefulWidget {
  const TeamScreen({super.key});

  @override
  State<TeamScreen> createState() => _TeamScreenState();
}

class _TeamScreenState extends State<TeamScreen> {
  int _version = 0;

  Future<List<dynamic>> _load() async =>
      await AppScope.read(context).api.get('/org/team') as List<dynamic>;

  Future<void> _toggle(Map<String, dynamic> m, bool active) async {
    try {
      await AppScope.read(context).api.patch('/org/team/${m['id']}', {'active': active});
      if (mounted) setState(() => _version++);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _add() async {
    final added = await showDialog<bool>(context: context, builder: (_) => const _AddMemberDialog());
    if (added == true && mounted) setState(() => _version++);
  }

  @override
  Widget build(BuildContext context) {
    final me = AppScope.of(context).user?['id'];
    return Scaffold(
      appBar: AppBar(title: const Text('Team'), actions: const [AccountMenu()]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.person_add_alt),
        label: const Text('Add member'),
      ),
      body: Loader<List<dynamic>>(
        key: ValueKey(_version),
        load: _load,
        builder: (context, team, _) => MaxWidth(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            children: [
              for (final m in team.cast<Map<String, dynamic>>())
                Card(
                  child: SwitchListTile(
                    secondary: CircleAvatar(child: Text((m['name'] as String)[0])),
                    title: Text(m['name'] as String),
                    subtitle: Text('${m['email']} · ${m['role'] == 'admin' ? 'Admin' : 'Loan officer'}'),
                    value: m['active'] == 1 || m['active'] == true,
                    onChanged: m['id'] == me ? null : (v) => _toggle(m, v),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddMemberDialog extends StatefulWidget {
  const _AddMemberDialog();

  @override
  State<_AddMemberDialog> createState() => _AddMemberDialogState();
}

class _AddMemberDialogState extends State<_AddMemberDialog> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  String _role = 'officer';
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await AppScope.read(context).api.post('/org/team', {
        'name': _name.text.trim(),
        'email': _email.text.trim(),
        'password': _password.text,
        'role': _role,
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add team member'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: _name, decoration: const InputDecoration(labelText: 'Full name')),
            TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Work email')),
            TextField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Temporary password (8+ characters)')),
            const SizedBox(height: 16),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'officer', label: Text('Loan officer')),
                ButtonSegment(value: 'admin', label: Text('Admin')),
              ],
              selected: {_role},
              onSelectionChanged: (s) => setState(() => _role = s.first),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('Add')),
      ],
    );
  }
}
