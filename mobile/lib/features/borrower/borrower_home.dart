import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/session.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/theme.dart';
import '../../shared/widgets/common.dart';
import '../../shared/widgets/odds.dart';
import '../readiness/draft_controller.dart';

final borrowerHomeProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final api = ref.watch(apiProvider);
  final results = await Future.wait([api.get('/drafts'), api.get('/applications/mine'), api.get('/loans')]);
  await ref.read(sessionProvider.notifier).refreshMe();
  return {'drafts': results[0], 'applications': results[1], 'loans': results[2]};
});

class BorrowerHomeScreen extends ConsumerWidget {
  const BorrowerHomeScreen({super.key});

  String _greeting(BuildContext context) {
    final h = DateTime.now().hour;
    return context.t(h < 12 ? 'home.morning' : (h < 17 ? 'home.afternoon' : 'home.evening'));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final data = ref.watch(borrowerHomeProvider);
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: AsyncView<Map<String, dynamic>>(
          value: data,
          onRetry: () => ref.invalidate(borrowerHomeProvider),
          builder: (d) {
            final drafts = (d['drafts'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
            final apps = (d['applications'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
            final loans = (d['loans'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
            final open = apps.where((a) => ['submitted', 'in_review', 'needs_docs'].contains(a['status'])).toList();
            final activeLoans = loans.where((l) => l['status'] == 'active').toList();
            return PageList(
              onRefresh: () async => ref.invalidate(borrowerHomeProvider),
              children: [
                const SizedBox(height: 8),
                Text('${_greeting(context)}, ${session.name.split(' ').first}', style: theme.textTheme.headlineSmall),
                const SizedBox(height: 4),
                Text(context.t('home.subtitle'), style: theme.textTheme.bodyMedium?.copyWith(color: Brand.muted)),
                const SizedBox(height: 16),
                _ActionCard(drafts: drafts, open: open, activeLoans: activeLoans),
                if (open.isNotEmpty) ...[
                  SectionTitle(context.t('home.in_progress'),
                      trailing: TextButton(onPressed: () => context.go('/applications'), child: Text(context.t('common.see_all')))),
                  for (final a in open.take(3))
                    Card(
                      child: ListTile(
                        title: Text(a['lender'] as String),
                        subtitle: Text('${context.money(a['loan_amount'] as num?)} · ${context.date(a['created_at'] as String?)}'),
                        trailing: StatusChip(status: a['status'] as String?, dense: true),
                        onTap: () => context.go('/applications/${a['id']}'),
                      ),
                    ),
                ],
                if (activeLoans.isNotEmpty) ...[
                  SectionTitle(context.t('home.loans')),
                  for (final l in activeLoans)
                    Card(
                      child: ListTile(
                        leading: IconTile(icon: Icons.account_balance_wallet_outlined, color: theme.colorScheme.primary),
                        title: Text(l['lender'] as String),
                        subtitle: Text(l['next_due'] == null
                            ? context.t('loans.all_paid')
                            : context.t('loans.next_due', {
                                'amount': context.money((l['next_due'] as Map)['amount_due'] as num?),
                                'date': context.date((l['next_due'] as Map)['due_date'] as String?),
                              })),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => context.go('/loans/${l['id']}'),
                      ),
                    ),
                ],
                SectionTitle(context.t('home.levels')),
                _LevelsCard(levels: session.levels),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The next best action, decided from what the borrower has going on.
class _ActionCard extends ConsumerWidget {
  final List<Map<String, dynamic>> drafts;
  final List<Map<String, dynamic>> open;
  final List<Map<String, dynamic>> activeLoans;

  const _ActionCard({required this.drafts, required this.open, required this.activeLoans});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final needsDocs = open.where((a) => a['status'] == 'needs_docs').toList();
    final overdue = activeLoans.where((l) => (l['overdue'] as List? ?? const []).isNotEmpty).toList();
    String title;
    String body;
    String cta;
    IconData icon;
    VoidCallback onTap;
    if (overdue.isNotEmpty) {
      title = context.t('action.overdue');
      body = context.t('action.overdue_sub');
      cta = context.t('action.pay');
      icon = Icons.warning_amber_rounded;
      onTap = () => context.go('/loans/${overdue.first['id']}');
    } else if (needsDocs.isNotEmpty) {
      title = context.t('action.docs');
      body = context.t('action.docs_sub', {'lender': needsDocs.first['lender']});
      cta = context.t('action.upload');
      icon = Icons.upload_file;
      onTap = () => context.go('/applications/${needsDocs.first['id']}');
    } else if (drafts.isNotEmpty) {
      title = context.t('action.continue');
      body = context.t('action.continue_sub');
      cta = context.t('action.resume');
      icon = Icons.play_circle_outline;
      onTap = () async {
        await ref.read(draftProvider.notifier).open(drafts.first['id'] as int);
        if (context.mounted) {
          context.go(drafts.first['quick_check_done'] == true ? '/offers' : '/check');
        }
      };
    } else {
      title = context.t('action.check');
      body = context.t('action.check_sub');
      cta = context.t('welcome.cta');
      icon = Icons.bolt_rounded;
      onTap = () async {
        await ref.read(draftProvider.notifier).reset();
        if (context.mounted) context.go('/check');
      };
    }
    return Card(
      color: theme.colorScheme.primary,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(child: Text(title, style: theme.textTheme.titleMedium?.copyWith(color: Colors.white))),
          ]),
          const SizedBox(height: 6),
          Text(body, style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white70)),
          const SizedBox(height: 14),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: theme.colorScheme.primary),
            onPressed: onTap,
            child: Text(cta),
          ),
        ]),
      ),
    );
  }
}

/// "Start small, grow": the borrower's credit level with each lender.
class _LevelsCard extends StatelessWidget {
  final List<Map<String, dynamic>> levels;
  const _LevelsCard({required this.levels});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (levels.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(context.t('ladder.explain'), style: theme.textTheme.bodySmall),
          for (final l in levels) ...[
            const Divider(height: 24),
            Row(children: [
              Expanded(child: Text(l['lender'] as String, style: theme.textTheme.titleSmall)),
              Pill(
                  label: context.t('ladder.level', {'n': context.digits(l['level']), 'name': context.code('ladder', l['name'] as String?)}),
                  color: Brand.info,
                  icon: Icons.stairs_outlined,
                  dense: true),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              for (var i = 1; i <= 4; i++)
                Expanded(
                  child: Container(
                    height: 6,
                    margin: EdgeInsets.only(right: i < 4 ? 4 : 0),
                    decoration: BoxDecoration(
                      color: i <= (l['level'] as num) ? Brand.info : theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
            ]),
            const SizedBox(height: 6),
            Text(
                context.t('ladder.limit', {'amount': context.money(l['max_amount'] as num?, currency: (l['currency'] as String?) ?? 'BDT')}),
                style: theme.textTheme.bodySmall),
            if (l['next_requirement'] != null)
              Text(
                  context.t('ladder.next', {
                    'req': context.code('ladder', l['next_requirement'] as String?),
                    'amount': context.money(l['next_level_max'] as num?, currency: (l['currency'] as String?) ?? 'BDT'),
                  }),
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary)),
          ],
        ]),
      ),
    );
  }
}

/// Re-exported for screens that show odds for an application.
class AppOdds extends StatelessWidget {
  final String? odds;
  const AppOdds(this.odds, {super.key});

  @override
  Widget build(BuildContext context) => odds == null ? const SizedBox.shrink() : OddsChip(odds: odds, dense: true);
}
