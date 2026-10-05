import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../widgets/account_menu.dart';
import '../../widgets/common.dart';

/// Platform owner: lender organisations (tenants), plans and platform totals.
class SuperConsole extends StatefulWidget {
  const SuperConsole({super.key});

  @override
  State<SuperConsole> createState() => _SuperConsoleState();
}

class _SuperConsoleState extends State<SuperConsole> {
  int _version = 0;

  Future<(Map<String, dynamic>, List<dynamic>)> _load() async {
    final api = AppScope.read(context).api;
    final stats = await api.get('/admin/stats') as Map<String, dynamic>;
    final orgs = await api.get('/admin/orgs') as List<dynamic>;
    return (stats, orgs);
  }

  Future<void> _toggle(Map<String, dynamic> org, bool active) async {
    try {
      await AppScope.read(context).api.patch('/admin/orgs/${org['id']}', {'active': active});
      if (mounted) setState(() => _version++);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _create() async {
    final ok = await showDialog<bool>(context: context, builder: (_) => const _CreateOrgDialog());
    if (ok == true && mounted) setState(() => _version++);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('LenDen platform'), actions: const [AccountMenu()]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add_business),
        label: const Text('New lender'),
      ),
      body: Loader<(Map<String, dynamic>, List<dynamic>)>(
        key: ValueKey(_version),
        load: _load,
        builder: (context, data, _) {
          final (stats, orgs) = data;
          final plans = Map<String, dynamic>.from(stats['plans'] as Map);
          return MaxWidth(
            width: 1000,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: [
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    StatCard(label: 'Lenders', value: '${stats['active_orgs']} / ${stats['orgs']}',
                        icon: Icons.account_balance),
                    StatCard(label: 'Borrowers', value: '${stats['borrowers']}', icon: Icons.people_outline),
                    StatCard(label: 'Staff seats', value: '${stats['staff']}', icon: Icons.badge_outlined),
                    StatCard(label: 'Applications', value: '${stats['applications']}',
                        icon: Icons.description_outlined),
                  ],
                ),
                SectionTitle('Lenders',
                    trailing: Text(plans.entries.map((e) => '${e.value} ${e.key}').join(' · '))),
                for (final o in orgs.cast<Map<String, dynamic>>())
                  Card(
                    child: SwitchListTile(
                      secondary: const Icon(Icons.account_balance_outlined),
                      title: Text(o['name'] as String),
                      subtitle: Text('${(o['plan'] as String).toUpperCase()} plan · ${o['staff']} staff · '
                          '${o['applications']} applications'),
                      value: o['active'] == 1 || o['active'] == true,
                      onChanged: (v) => _toggle(o, v),
                    ),
                  ),
                const SizedBox(height: 8),
                Text('Switching a lender off suspends its staff logins and hides it from borrowers.',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _CreateOrgDialog extends StatefulWidget {
  const _CreateOrgDialog();

  @override
  State<_CreateOrgDialog> createState() => _CreateOrgDialogState();
}

class _CreateOrgDialogState extends State<_CreateOrgDialog> {
  final _name = TextEditingController();
  final _adminName = TextEditingController();
  final _adminEmail = TextEditingController();
  final _adminPassword = TextEditingController();
  String _plan = 'free';
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_name, _adminName, _adminEmail, _adminPassword]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await AppScope.read(context).api.post('/admin/orgs', {
        'name': _name.text.trim(),
        'plan': _plan,
        'admin_name': _adminName.text.trim(),
        'admin_email': _adminEmail.text.trim(),
        'admin_password': _adminPassword.text,
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
      title: const Text('New lender organisation'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: _name, decoration: const InputDecoration(labelText: 'Organisation name')),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'free', label: Text('Free')),
                  ButtonSegment(value: 'pro', label: Text('Pro')),
                  ButtonSegment(value: 'enterprise', label: Text('Enterprise')),
                ],
                selected: {_plan},
                onSelectionChanged: (s) => setState(() => _plan = s.first),
              ),
              TextField(controller: _adminName, decoration: const InputDecoration(labelText: 'Admin name')),
              TextField(
                  controller: _adminEmail,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'Admin email')),
              TextField(
                  controller: _adminPassword,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Temporary password (8+ characters)')),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('Create')),
      ],
    );
  }
}
