import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/session.dart';
import '../../core/l10n/l10n.dart';
import '../../shared/widgets/brand.dart';
import '../../shared/widgets/common.dart';

final inboxProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final res = await ref.watch(apiProvider).get('/notifications', query: {'limit': '50'}) as Map<String, dynamic>;
  return res;
});

const _icons = {
  'account.welcome': Icons.waving_hand_outlined,
  'application.submitted': Icons.send_outlined,
  'application.approved': Icons.celebration_outlined,
  'application.rejected': Icons.info_outline,
  'documents.requested': Icons.upload_file,
  'documents.reminder': Icons.alarm,
  'documents.expired': Icons.timer_off_outlined,
  'documents.received': Icons.inventory_2_outlined,
  'draft.reminder': Icons.edit_note,
  'repayment.due_soon': Icons.event_outlined,
  'repayment.late': Icons.warning_amber_rounded,
  'repayment.missed': Icons.error_outline,
  'loan.closed': Icons.emoji_events_outlined,
};

/// In-app notifications. Every event the server sends also lands here.
class InboxScreen extends ConsumerWidget {
  final String basePath;
  const InboxScreen({super.key, this.basePath = ''});

  String? _target(Map<String, dynamic> n) {
    final p = Map<String, dynamic>.from(n['payload'] as Map? ?? const {});
    if (basePath == '/staff') {
      return p['application_id'] != null ? '/staff/applications/${p['application_id']}' : null;
    }
    if (p['loan_id'] != null && (n['event'] as String).startsWith(RegExp('repayment|loan'))) return '/loans/${p['loan_id']}';
    if (p['application_id'] != null) return '/applications/${p['application_id']}';
    if (n['event'] == 'draft.reminder') return '/check';
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inbox = ref.watch(inboxProvider);
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: AsyncView<Map<String, dynamic>>(
          value: inbox,
          onRetry: () => ref.invalidate(inboxProvider),
          builder: (d) {
            final items = (d['items'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
            final unread = (d['unread'] as num).toInt();
            return PageList(onRefresh: () async => ref.invalidate(inboxProvider), children: [
              PageHeader(
                title: context.t('inbox.title'),
                subtitle: unread > 0 ? context.t('inbox.unread', {'n': context.digits(unread)}) : context.t('inbox.all_read'),
                trailing: unread > 0
                    ? TextButton(
                        onPressed: () async {
                          await runBusy(context, () => ref.read(apiProvider).post('/notifications/read-all'));
                          ref.read(sessionProvider.notifier).setUnread(0);
                          ref.invalidate(inboxProvider);
                        },
                        child: Text(context.t('inbox.mark_all')))
                    : null,
              ),
              if (items.isEmpty) EmptyState(icon: Icons.notifications_none, title: context.t('inbox.empty')),
              for (final n in items)
                Card(
                  color: n['read_at'] == null ? theme.colorScheme.primaryContainer.withValues(alpha: 0.25) : null,
                  child: ListTile(
                    leading: IconTile(icon: _icons[n['event']] ?? Icons.notifications_outlined, color: theme.colorScheme.primary),
                    title: Text(context.code('event', n['event'] as String?, fallback: n['event'] as String?),
                        style: TextStyle(fontWeight: n['read_at'] == null ? FontWeight.w700 : FontWeight.w500)),
                    subtitle: Text(_subtitle(context, n)),
                    trailing: Text(context.ago(n['created_at'] as String?), style: theme.textTheme.bodySmall),
                    onTap: () async {
                      if (n['read_at'] == null) {
                        try {
                          await ref.read(apiProvider).post('/notifications/${n['id']}/read');
                          ref.read(sessionProvider.notifier).setUnread((unread - 1).clamp(0, 1 << 20).toInt());
                        } catch (_) {}
                        ref.invalidate(inboxProvider);
                      }
                      final t = _target(n);
                      if (t != null && context.mounted) context.go(t);
                    },
                  ),
                ),
            ]);
          },
        ),
      ),
    );
  }

  String _subtitle(BuildContext context, Map<String, dynamic> n) {
    final p = Map<String, dynamic>.from(n['payload'] as Map? ?? const {});
    final args = <String, Object?>{
      for (final e in p.entries) e.key: e.value is num && (e.key == 'amount') ? context.money(e.value as num) : e.value,
    };
    if (args['lender'] == null) args['lender'] = '';
    final key = 'event_body.${n['event']}';
    return L10n.has(key) ? context.t(key, args) : '';
  }
}

/// Keeps the unread badge fresh when a shell is shown.
final unreadPollProvider = FutureProvider.autoDispose<int>((ref) async {
  final res = await ref.watch(apiProvider).get('/notifications', query: {'limit': '1', 'unread_only': 'true'}) as Map<String, dynamic>;
  final n = (res['unread'] as num).toInt();
  ref.read(sessionProvider.notifier).setUnread(n);
  return n;
});
