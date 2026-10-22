import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/session.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/theme.dart';
import '../../shared/widgets/brand.dart';
import '../../shared/widgets/common.dart';
import '../../shared/widgets/odds.dart';

@immutable
class QueueFilter {
  final String status;
  final String assigned; // '', 'me', 'unassigned'
  final String? odds;
  final String sort;

  const QueueFilter({this.status = 'pending', this.assigned = '', this.odds, this.sort = 'risk'});

  QueueFilter copyWith({String? status, String? assigned, String? odds, bool clearOdds = false, String? sort}) => QueueFilter(
      status: status ?? this.status,
      assigned: assigned ?? this.assigned,
      odds: clearOdds ? null : (odds ?? this.odds),
      sort: sort ?? this.sort);

  Map<String, String> query(int offset) => {
        if (status != 'all') 'status': status,
        if (assigned.isNotEmpty) 'assigned': assigned,
        if (odds != null) 'odds': odds!,
        'sort': sort,
        'limit': '30',
        'offset': '$offset',
      };

  @override
  bool operator ==(Object other) =>
      other is QueueFilter && other.status == status && other.assigned == assigned && other.odds == odds && other.sort == sort;

  @override
  int get hashCode => Object.hash(status, assigned, odds, sort);
}

class QueueFilterController extends Notifier<QueueFilter> {
  @override
  QueueFilter build() => const QueueFilter();
  void set(QueueFilter f) => state = f;
}

final queueFilterProvider = NotifierProvider<QueueFilterController, QueueFilter>(QueueFilterController.new);

final queueProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, int>((ref, pages) async {
  final f = ref.watch(queueFilterProvider);
  final api = ref.watch(apiProvider);
  final items = <dynamic>[];
  var total = 0;
  for (var p = 0; p < pages; p++) {
    final res = await api.get('/org/applications', query: f.query(p * 30)) as Map<String, dynamic>;
    items.addAll(res['items'] as List);
    total = (res['total'] as num).toInt();
    if (res['next_cursor'] == null) break;
  }
  return {'items': items, 'total': total};
});

/// Risk-sorted queue with filters, SLA timers and who is reviewing what.
class QueueScreen extends ConsumerStatefulWidget {
  const QueueScreen({super.key});

  @override
  ConsumerState<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends ConsumerState<QueueScreen> {
  int _pages = 1;

  @override
  Widget build(BuildContext context) {
    final f = ref.watch(queueFilterProvider);
    final data = ref.watch(queueProvider(_pages));
    final ctrl = ref.read(queueFilterProvider.notifier);
    final theme = Theme.of(context);
    void setF(QueueFilter n) {
      setState(() => _pages = 1);
      ctrl.set(n);
    }

    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: MaxWidth(
              width: 1100,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                PageHeader(
                  title: context.t('queue.title'),
                  subtitle: ref.watch(sessionProvider).orgName,
                  trailing: IconButton(
                      tooltip: context.t('common.refresh'),
                      icon: const Icon(Icons.refresh),
                      onPressed: () => ref.invalidate(queueProvider)),
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    for (final s in ['pending', 'submitted', 'in_review', 'needs_docs', 'approved', 'rejected', 'all'])
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(s == 'pending' || s == 'all' ? context.t('queue.$s') : context.code('status', s)),
                          selected: f.status == s,
                          onSelected: (_) => setF(f.copyWith(status: s)),
                        ),
                      ),
                  ]),
                ),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(value: '', label: Text(context.t('queue.everyone'))),
                      ButtonSegment(value: 'me', label: Text(context.t('queue.mine'))),
                      ButtonSegment(value: 'unassigned', label: Text(context.t('queue.unassigned'))),
                    ],
                    selected: {f.assigned},
                    onSelectionChanged: (v) => setF(f.copyWith(assigned: v.first)),
                  ),
                  DropdownButton<String?>(
                    value: f.odds,
                    hint: Text(context.t('queue.any_odds')),
                    underline: const SizedBox.shrink(),
                    items: [
                      DropdownMenuItem<String?>(value: null, child: Text(context.t('queue.any_odds'))),
                      for (final o in ['excellent', 'good', 'fair', 'low'])
                        DropdownMenuItem<String?>(value: o, child: Text(context.code('odds', o))),
                    ],
                    onChanged: (v) => setF(v == null ? f.copyWith(clearOdds: true) : f.copyWith(odds: v)),
                  ),
                  DropdownButton<String>(
                    value: f.sort,
                    underline: const SizedBox.shrink(),
                    items: [
                      for (final s in ['risk', 'sla', 'newest', 'oldest', 'amount'])
                        DropdownMenuItem(value: s, child: Text(context.t('queue.sort_$s'))),
                    ],
                    onChanged: (v) => setF(f.copyWith(sort: v)),
                  ),
                ]),
                const SizedBox(height: 8),
              ]),
            ),
          ),
          Expanded(
            child: AsyncView<Map<String, dynamic>>(
              value: data,
              onRetry: () => ref.invalidate(queueProvider),
              builder: (d) {
                final items = (d['items'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
                final total = (d['total'] as num).toInt();
                return RefreshIndicator(
                  onRefresh: () async => ref.invalidate(queueProvider),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    children: [
                      MaxWidth(
                        width: 1100,
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Text(context.t('queue.count', {'n': context.digits(total)}), style: theme.textTheme.bodySmall),
                          const SizedBox(height: 6),
                          if (items.isEmpty) EmptyState(icon: Icons.inbox_outlined, title: context.t('queue.empty')),
                          for (final a in items) _QueueRow(a: a),
                          if (items.length < total)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: OutlinedButton(
                                  onPressed: () => setState(() => _pages++), child: Text(context.t('common.load_more'))),
                            ),
                        ]),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }
}

class _QueueRow extends StatelessWidget {
  final Map<String, dynamic> a;
  const _QueueRow({required this.a});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final breached = a['sla_breached'] == true;
    final open = ['submitted', 'in_review', 'needs_docs'].contains(a['status']);
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(Space.radius),
        onTap: () => context.go('/staff/applications/${a['id']}'),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            SizedBox(
              width: 52,
              child: Column(children: [
                Text(context.pct(a['default_probability'] as num?, digits: 0), style: theme.textTheme.titleMedium),
                Text(context.t('queue.risk'), style: theme.textTheme.bodySmall),
              ]),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(a['borrower_name'] as String? ?? '-', style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(
                    '${context.money(a['loan_amount'] as num?)} · ${context.code('option.LoanPurpose', a['loan_purpose'] as String?)} · ${context.ago(a['created_at'] as String?)}',
                    style: theme.textTheme.bodySmall),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 4, children: [
                  StatusChip(status: a['status'] as String?, dense: true),
                  OddsChip(odds: a['odds'] as String?, dense: true),
                  if (a['recommendation'] == 'APPROVE')
                    Pill(label: context.t('queue.recommend_approve'), color: Brand.success, dense: true),
                  if (open && breached)
                    Pill(label: context.t('queue.sla_breached'), color: Brand.danger, icon: Icons.timer_off_outlined, dense: true)
                  else if (open && a['sla_due_at'] != null)
                    Pill(label: context.t('queue.sla_due', {'when': context.ago(a['sla_due_at'] as String?)}), color: Brand.muted, icon: Icons.timer_outlined, dense: true),
                  if (a['assigned_name'] != null)
                    Pill(label: a['assigned_name'] as String, color: Brand.info, icon: Icons.person_outline, dense: true),
                ]),
              ]),
            ),
            const Icon(Icons.chevron_right),
          ]),
        ),
      ),
    );
  }
}
