import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_client.dart';
import '../../core/auth/session.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/theme.dart';
import '../../shared/widgets/brand.dart';
import '../../shared/widgets/common.dart';

final myLoansProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final res = await ref.watch(apiProvider).get('/loans') as List;
  return res.map((e) => Map<String, dynamic>.from(e as Map)).toList();
});

final loanProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, int>((ref, id) async {
  return await ref.watch(apiProvider).get('/loans/$id') as Map<String, dynamic>;
});

class LoansScreen extends ConsumerWidget {
  const LoansScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loans = ref.watch(myLoansProvider);
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: AsyncView<List<Map<String, dynamic>>>(
          value: loans,
          onRetry: () => ref.invalidate(myLoansProvider),
          builder: (list) => PageList(
            onRefresh: () async => ref.invalidate(myLoansProvider),
            children: [
              PageHeader(title: context.t('loans.title'), subtitle: context.t('loans.subtitle')),
              if (list.isEmpty)
                EmptyState(icon: Icons.account_balance_wallet_outlined, title: context.t('loans.empty'), message: context.t('loans.empty_sub')),
              for (final l in list)
                Card(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(Space.radius),
                    onTap: () => context.go('/loans/${l['id']}'),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Expanded(child: Text(l['lender'] as String, style: theme.textTheme.titleMedium)),
                          StatusChip(status: l['status'] as String?, dense: true),
                        ]),
                        const SizedBox(height: 10),
                        LinearProgressIndicator(
                          value: (l['installments'] as num) == 0 ? 0.0 : (l['installments_paid'] as num) / (l['installments'] as num),
                          minHeight: 8,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        const SizedBox(height: 6),
                        Text(
                            context.t('loans.progress', {
                              'paid': context.digits(l['installments_paid']),
                              'total': context.digits(l['installments']),
                              'left': context.money(l['outstanding'] as num?),
                            }),
                            style: theme.textTheme.bodySmall),
                        if ((l['overdue'] as List? ?? const []).isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Pill(label: context.t('loans.overdue'), color: Brand.danger, icon: Icons.warning_amber, dense: true),
                          ),
                      ]),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class LoanDetailScreen extends ConsumerStatefulWidget {
  final int id;
  const LoanDetailScreen({super.key, required this.id});

  @override
  ConsumerState<LoanDetailScreen> createState() => _LoanDetailScreenState();
}

class _LoanDetailScreenState extends ConsumerState<LoanDetailScreen> {
  bool _busy = false;

  Future<void> _pay(num amount) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(context.t('loans.pay_q', {'amount': context.money(amount)})),
        content: Text(context.t('loans.pay_mock')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(context.t('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(context.t('loans.pay'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    final key = ApiClient.newIdempotencyKey();
    await runBusy(context, () async {
      final res = await ref.read(apiProvider).post('/loans/${widget.id}/repayments', {'amount': amount}, key) as Map<String, dynamic>;
      ref.invalidate(loanProvider(widget.id));
      ref.invalidate(myLoansProvider);
      if (!mounted) return;
      if (res['status'] == 'closed') {
        await ref.read(sessionProvider.notifier).refreshMe();
        if (mounted) showInfo(context, context.t('loans.closed_msg'));
      } else {
        showInfo(context, context.t('loans.paid_msg'));
      }
    });
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final loan = ref.watch(loanProvider(widget.id));
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => context.go('/loans')),
        title: Text(context.t('loans.detail')),
      ),
      body: AsyncView<Map<String, dynamic>>(
        value: loan,
        onRetry: () => ref.invalidate(loanProvider(widget.id)),
        builder: (l) {
          final schedule = (l['schedule'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
          final next = l['next_due'] == null ? null : Map<String, dynamic>.from(l['next_due'] as Map);
          final active = l['status'] == 'active';
          final nextAmount = next == null ? null : (next['amount_due'] as num) - (next['amount_paid'] as num);
          return PageList(onRefresh: () async => ref.invalidate(loanProvider(widget.id)), children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text(l['lender'] as String, style: theme.textTheme.titleLarge)),
                    StatusChip(status: l['status'] as String?),
                  ]),
                  const SizedBox(height: 8),
                  KeyValue(context.t('loans.principal'), context.money(l['principal'] as num?), strong: true),
                  KeyValue(context.t('offers.rate'), context.t('common.rate_pa', {'rate': context.num0(l['annual_rate'] as num?, digits: 1)})),
                  KeyValue(context.t('offers.emi'), context.money(l['emi'] as num?)),
                  KeyValue(context.t('loans.total'), context.money(l['total_repayable'] as num?)),
                  KeyValue(context.t('loans.paid_so_far'), context.money(l['paid'] as num?)),
                  KeyValue(context.t('loans.outstanding'), context.money(l['outstanding'] as num?), strong: true),
                ]),
              ),
            ),
            if (active && next != null && nextAmount != null)
              Card(
                color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(context.t('loans.next_title'), style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(context.t('loans.next_due', {'amount': context.money(nextAmount), 'date': context.date(next['due_date'] as String?)})),
                    const SizedBox(height: 12),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      FilledButton.icon(
                          onPressed: _busy ? null : () => _pay(nextAmount),
                          icon: const Icon(Icons.payments_outlined),
                          label: Text(context.t('loans.pay_next'))),
                      OutlinedButton(
                          onPressed: _busy ? null : () => _pay(l['outstanding'] as num), child: Text(context.t('loans.pay_all'))),
                    ]),
                    const SizedBox(height: 6),
                    Text(context.t('loans.ladder_hint'), style: theme.textTheme.bodySmall),
                  ]),
                ),
              ),
            SectionTitle(context.t('loans.schedule')),
            Card(
              child: Column(children: [
                for (final r in schedule)
                  ListTile(
                    dense: true,
                    leading: CircleAvatar(radius: 14, child: Text(context.digits(r['seq']), style: const TextStyle(fontSize: 12))),
                    title: Text(context.money(r['amount_due'] as num?)),
                    subtitle: Text(r['paid_at'] != null
                        ? context.t('loans.paid_on', {'date': context.date(r['paid_at'] as String?)})
                        : context.t('loans.due_on', {'date': context.date(r['due_date'] as String?)})),
                    trailing: StatusChip(status: r['status'] as String?, dense: true),
                  ),
              ]),
            ),
          ]);
        },
      ),
    );
  }
}
