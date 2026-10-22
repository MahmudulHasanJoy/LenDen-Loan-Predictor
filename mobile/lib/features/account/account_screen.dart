import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/session.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/theme.dart';
import '../../shared/widgets/brand.dart';
import '../../shared/widgets/common.dart';

final consentsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final res = await ref.watch(apiProvider).get('/me/consents') as List;
  return res.map((e) => Map<String, dynamic>.from(e as Map)).toList();
});

/// Profile, language, notifications, security and privacy (consents, export, delete).
class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sessionProvider);
    final theme = Theme.of(context);
    final user = s.user ?? const {};
    final prefs = Map<String, dynamic>.from(user['notification_prefs'] as Map? ?? const {'email': true});
    return Scaffold(
      body: SafeArea(
        child: PageList(children: [
          PageHeader(title: context.t('account.title'), subtitle: s.isStaff ? '${s.orgName} · ${context.code('role', s.role)}' : s.email),
          Card(
            child: Column(children: [
              ListTile(
                leading: CircleAvatar(child: Text(s.name.isEmpty ? '?' : s.name[0].toUpperCase())),
                title: Text(s.name),
                subtitle: Text(s.email),
                trailing: IconButton(icon: const Icon(Icons.edit_outlined), onPressed: () => _editName(context, ref, s.name)),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.translate),
                title: Text(context.t('account.language')),
                trailing: const LanguageToggle(),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.mail_outline),
                title: Text(context.t('account.email_updates')),
                subtitle: Text(context.t('account.email_updates_sub')),
                value: prefs['email'] != false,
                onChanged: (v) => runBusy(context, () async {
                  await ref.read(apiProvider).put('/me', {
                    'notification_prefs': {'email': v}
                  });
                  await ref.read(sessionProvider.notifier).refreshMe();
                }),
              ),
            ]),
          ),
          SectionTitle(context.t('account.security')),
          Card(
            child: Column(children: [
              ListTile(
                leading: const Icon(Icons.phone_iphone),
                title: Text(context.t('field.phone')),
                subtitle: Text(user['phone'] == null
                    ? context.t('account.phone_none')
                    : '${user['phone']} · ${user['phone_verified'] == true ? context.t('account.verified') : context.t('account.not_verified')}'),
                trailing: TextButton(onPressed: () => _verifyPhone(context, ref), child: Text(context.t('account.verify'))),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.password),
                title: Text(context.t('account.change_password')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _changePassword(context, ref),
              ),
              if (!s.isBorrower) ...[
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.verified_user_outlined),
                  title: Text(context.t('account.two_factor')),
                  subtitle: Text(user['totp_enabled'] == true ? context.t('account.on') : context.t('account.off')),
                  trailing: TextButton(
                    onPressed: () => user['totp_enabled'] == true ? _disable2fa(context, ref) : _setup2fa(context, ref),
                    child: Text(user['totp_enabled'] == true ? context.t('account.turn_off') : context.t('account.turn_on')),
                  ),
                ),
              ],
            ]),
          ),
          if (s.isStaff) ...[
            SectionTitle(context.t('account.workspace')),
            Card(
              child: Column(children: [
                ListTile(
                    leading: const Icon(Icons.notifications_none),
                    title: Text(context.t('nav.inbox')),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.go('/staff/inbox')),
                if (s.isAdmin) ...[
                  const Divider(),
                  ListTile(
                      leading: const Icon(Icons.tune_outlined),
                      title: Text(context.t('nav.rules')),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => context.go('/staff/rules')),
                  const Divider(),
                  ListTile(
                      leading: const Icon(Icons.group_outlined),
                      title: Text(context.t('nav.team')),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => context.go('/staff/team')),
                  const Divider(),
                  ListTile(
                      leading: const Icon(Icons.history_outlined),
                      title: Text(context.t('nav.audit')),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => context.go('/staff/audit')),
                ],
              ]),
            ),
          ],
          if (s.isBorrower) ...[
            SectionTitle(context.t('account.privacy')),
            const _Consents(),
            Card(
              child: Column(children: [
                ListTile(
                  leading: const Icon(Icons.download_outlined),
                  title: Text(context.t('account.export')),
                  subtitle: Text(context.t('account.export_sub')),
                  onTap: () => _export(context, ref),
                ),
                const Divider(),
                ListTile(
                  leading: Icon(Icons.delete_forever_outlined, color: theme.colorScheme.error),
                  title: Text(context.t('account.delete'), style: TextStyle(color: theme.colorScheme.error)),
                  subtitle: Text(context.t('account.delete_sub')),
                  onTap: () => _delete(context, ref),
                ),
              ]),
            ),
          ],
          const SizedBox(height: 16),
          Card(
            child: Column(children: [
              ListTile(
                  leading: const Icon(Icons.dns_outlined),
                  title: Text(context.t('server.title')),
                  subtitle: Text(ref.read(apiProvider).baseUrl),
                  onTap: () => context.push('/server')),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.logout),
                title: Text(context.t('account.logout')),
                onTap: () async {
                  await ref.read(sessionProvider.notifier).logout();
                  if (context.mounted) context.go('/');
                },
              ),
            ]),
          ),
          const SizedBox(height: 12),
          Text(context.t('welcome.disclaimer'), style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
        ]),
      ),
    );
  }

  Future<String?> _prompt(BuildContext context, String title,
      {String initial = '', String? label, bool obscure = false, TextInputType? keyboard, String? help}) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(title),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (help != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(help)),
          TextField(
              controller: c,
              autofocus: true,
              obscureText: obscure,
              keyboardType: keyboard,
              decoration: InputDecoration(labelText: label)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: Text(context.t('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(d, c.text), child: Text(context.t('common.ok'))),
        ],
      ),
    );
  }

  Future<void> _editName(BuildContext context, WidgetRef ref, String current) async {
    final name = await _prompt(context, context.t('account.edit_name'), initial: current, label: context.t('field.name'));
    if (name == null || !context.mounted) return;
    await runBusy(context, () async {
      await ref.read(apiProvider).put('/me', {'name': name});
      await ref.read(sessionProvider.notifier).refreshMe();
    });
  }

  Future<void> _verifyPhone(BuildContext context, WidgetRef ref) async {
    final phone = await _prompt(context, context.t('account.verify_phone'),
        label: context.t('field.phone'), keyboard: TextInputType.phone, help: context.t('account.verify_phone_help'));
    if (phone == null || phone.trim().isEmpty || !context.mounted) return;
    final sent = await runBusy(context, () async => await ref.read(apiProvider).post('/me/phone/request', {'phone': phone}) as Map<String, dynamic>);
    if (sent == null || !context.mounted) return;
    final code = await _prompt(context, context.t('login.code'),
        keyboard: TextInputType.number,
        help: sent['dev_code'] == null ? context.t('login.code_sent') : context.t('login.dev_code', {'code': sent['dev_code']}));
    if (code == null || !context.mounted) return;
    await runBusy(context, () async {
      await ref.read(apiProvider).post('/me/phone/verify', {'phone': phone, 'code': code, 'purpose': 'verify'});
      await ref.read(sessionProvider.notifier).refreshMe();
      if (context.mounted) showInfo(context, context.t('account.phone_done'));
    });
  }

  Future<void> _changePassword(BuildContext context, WidgetRef ref) async {
    final old = await _prompt(context, context.t('account.change_password'), label: context.t('account.current_password'), obscure: true);
    if (old == null || !context.mounted) return;
    final next = await _prompt(context, context.t('account.change_password'),
        label: context.t('reset.new_password'), obscure: true, help: context.t('register.password_help'));
    if (next == null || !context.mounted) return;
    await runBusy(context, () async {
      final res = await ref.read(apiProvider).post('/me/password', {'old_password': old, 'new_password': next}) as Map<String, dynamic>;
      await ref.read(sessionProvider.notifier).adopt(res);
      if (context.mounted) showInfo(context, context.t('account.password_done'));
    });
  }

  Future<void> _setup2fa(BuildContext context, WidgetRef ref) async {
    final setup = await runBusy(context, () async => await ref.read(apiProvider).post('/me/2fa/setup') as Map<String, dynamic>);
    if (setup == null || !context.mounted) return;
    final code = await showDialog<String>(
      context: context,
      builder: (d) {
        final c = TextEditingController();
        return AlertDialog(
          title: Text(context.t('account.two_factor')),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(context.t('account.2fa_help')),
            const SizedBox(height: 12),
            SelectableText(setup['secret'] as String, style: const TextStyle(fontFamily: 'monospace', fontSize: 16)),
            TextButton.icon(
              onPressed: () => Clipboard.setData(ClipboardData(text: setup['otpauth_uri'] as String)),
              icon: const Icon(Icons.copy, size: 16),
              label: Text(context.t('account.copy_link')),
            ),
            TextField(controller: c, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('login.totp'))),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d), child: Text(context.t('common.cancel'))),
            FilledButton(onPressed: () => Navigator.pop(d, c.text), child: Text(context.t('account.turn_on'))),
          ],
        );
      },
    );
    if (code == null || !context.mounted) return;
    await runBusy(context, () async {
      await ref.read(apiProvider).post('/me/2fa/enable', {'code': code});
      await ref.read(sessionProvider.notifier).refreshMe();
    });
  }

  Future<void> _disable2fa(BuildContext context, WidgetRef ref) async {
    final code = await _prompt(context, context.t('account.turn_off'), label: context.t('login.totp'), keyboard: TextInputType.number);
    if (code == null || !context.mounted) return;
    await runBusy(context, () async {
      await ref.read(apiProvider).post('/me/2fa/disable', {'code': code});
      await ref.read(sessionProvider.notifier).refreshMe();
    });
  }

  Future<void> _export(BuildContext context, WidgetRef ref) async {
    final data = await runBusy(context, () => ref.read(apiProvider).get('/me/export'));
    if (data == null || !context.mounted) return;
    final text = const JsonEncoder.withIndent('  ').convert(data);
    await showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(context.t('account.export')),
        content: SizedBox(
          width: 560,
          height: 420,
          child: SingleChildScrollView(child: SelectableText(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 12))),
        ),
        actions: [
          TextButton.icon(
            onPressed: () => Clipboard.setData(ClipboardData(text: text)),
            icon: const Icon(Icons.copy),
            label: Text(context.t('account.copy')),
          ),
          FilledButton(onPressed: () => Navigator.pop(d), child: Text(context.t('common.close'))),
        ],
      ),
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final pw = await _prompt(context, context.t('account.delete'),
        label: context.t('field.password'), obscure: true, help: context.t('account.delete_confirm'));
    if (pw == null || !context.mounted) return;
    final ok = await runBusy(context, () async {
      await ref.read(apiProvider).post('/me/delete', {'password': pw});
      return true;
    });
    if (ok == true) {
      await ref.read(sessionProvider.notifier).logout();
      if (context.mounted) context.go('/');
    }
  }
}

class _Consents extends ConsumerWidget {
  const _Consents();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final consents = ref.watch(consentsProvider);
    final theme = Theme.of(context);
    return AsyncView<List<Map<String, dynamic>>>(
      value: consents,
      onRetry: () => ref.invalidate(consentsProvider),
      builder: (list) => Card(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text(context.t('account.consents'), style: theme.textTheme.titleSmall),
          ),
          if (list.isEmpty)
            Padding(padding: const EdgeInsets.all(16), child: Text(context.t('account.no_consents'), style: theme.textTheme.bodySmall)),
          for (final c in list)
            ListTile(
              leading: Icon(c['revoked_at'] == null ? Icons.check_circle_outline : Icons.block,
                  color: c['revoked_at'] == null ? Brand.success : Brand.muted),
              title: Text(c['lender'] as String? ?? '-'),
              subtitle: Text(c['revoked_at'] == null
                  ? context.t('account.consent_given', {'date': context.date(c['granted_at'] as String?)})
                  : context.t('account.consent_revoked', {'date': context.date(c['revoked_at'] as String?)})),
              trailing: c['revoked_at'] != null
                  ? null
                  : TextButton(
                      onPressed: () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (d) => AlertDialog(
                            title: Text(context.t('account.revoke_q')),
                            content: Text(context.t('account.revoke_body')),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(d, false), child: Text(context.t('common.cancel'))),
                              FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(context.t('account.revoke'))),
                            ],
                          ),
                        );
                        if (ok == true && context.mounted) {
                          await runBusy(context, () => ref.read(apiProvider).post('/me/consents/${c['id']}/revoke'));
                          ref.invalidate(consentsProvider);
                        }
                      },
                      child: Text(context.t('account.revoke')),
                    ),
            ),
        ]),
      ),
    );
  }
}
