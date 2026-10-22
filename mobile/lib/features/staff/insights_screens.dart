import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/session.dart';
import '../../core/format.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/theme.dart';
import '../../shared/widgets/brand.dart';
import '../../shared/widgets/common.dart';

final dashboardProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  return await ref.watch(apiProvider).get('/org/dashboard') as Map<String, dynamic>;
});

final fairnessProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  return await ref.watch(apiProvider).get('/org/fairness') as Map<String, dynamic>;
});

final portfolioProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final api = ref.watch(apiProvider);
  final res = await Future.wait([api.get('/org/portfolio'), api.get('/org/loans', query: {'status': 'active'})]);
  return {'summary': res[0], 'loans': res[1]};
});

/// Horizontal bars for a small categorical breakdown.
class BarBreakdown extends StatelessWidget {
  final List<(String, num, Color)> rows;
  const BarBreakdown({super.key, required this.rows});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = rows.fold<num>(0, (a, r) => a + r.$2);
    return Column(children: [
      for (final r in rows)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            SizedBox(width: 110, child: Text(r.$1, style: theme.textTheme.bodySmall)),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: total == 0 ? 0.0 : r.$2 / total,
                  minHeight: 10,
                  color: r.$3,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
              ),
            ),
            SizedBox(width: 44, child: Text(context.digits(r.$2), textAlign: TextAlign.right, style: theme.textTheme.bodySmall)),
          ]),
        ),
    ]);
  }
}

/// Applications per day as a tiny column chart.
class TrendChart extends StatelessWidget {
  final List<Map<String, dynamic>> points;
  const TrendChart({super.key, required this.points});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxV = points.fold<num>(1, (m, p) => (p['applications'] as num) > m ? p['applications'] as num : m);
    return SizedBox(
      height: 120,
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        for (final p in points)
          Expanded(
            child: Tooltip(
              message: '${context.date(p['date'] as String?)}: ${context.digits(p['applications'])}',
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 2),
                height: 8 + 104 * ((p['applications'] as num) / maxV),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(dashboardProvider);
    final s = ref.watch(sessionProvider);
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: AsyncView<Map<String, dynamic>>(
          value: data,
          onRetry: () => ref.invalidate(dashboardProvider),
          builder: (d) {
            final t = Map<String, dynamic>.from(d['totals'] as Map);
            final odds = Map<String, dynamic>.from(d['odds'] as Map);
            final drift = Map<String, dynamic>.from(d['drift'] as Map);
            final fairness = (d['fairness'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
            return PageList(
              width: 1100,
              onRefresh: () async => ref.invalidate(dashboardProvider),
              children: [
                PageHeader(title: context.t('dash.title'), subtitle: s.orgName),
                Wrap(spacing: 12, runSpacing: 12, children: [
                  StatCard(label: context.t('dash.pending'), value: context.digits(t['pending']), icon: Icons.inbox_outlined,
                      caption: context.t('dash.unassigned', {'n': context.digits(d['unassigned'])})),
                  StatCard(label: context.t('dash.my_queue'), value: context.digits(d['my_queue']), icon: Icons.person_outline, color: Brand.info),
                  StatCard(
                      label: context.t('dash.sla'),
                      value: context.digits(d['sla_breaches']),
                      icon: Icons.timer_off_outlined,
                      color: (d['sla_breaches'] as num) > 0 ? Brand.danger : Brand.success),
                  StatCard(label: context.t('dash.approval_rate'), value: context.pct(d['approval_rate'] as num?), icon: Icons.check_circle_outline, color: Brand.success),
                  StatCard(label: context.t('dash.override_rate'), value: context.pct(d['override_rate'] as num?), icon: Icons.swap_horiz, color: Brand.warning),
                  StatCard(
                      label: context.t('dash.hours'),
                      value: d['avg_hours_to_decision'] == null ? '-' : context.num0(d['avg_hours_to_decision'] as num, digits: 1),
                      icon: Icons.schedule,
                      caption: context.t('dash.hours_caption')),
                ]),
                SectionTitle(context.t('dash.trend')),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: TrendChart(points: (d['trend'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList()),
                  ),
                ),
                SectionTitle(context.t('dash.odds_mix')),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: BarBreakdown(rows: [
                      for (final o in ['excellent', 'good', 'fair', 'low'])
                        (context.code('odds', o), (odds[o] as num?) ?? 0, oddsColors[o]!),
                    ]),
                  ),
                ),
                SectionTitle(context.t('dash.fairness'),
                    trailing: s.isAdmin ? TextButton(onPressed: () => _fairness(context), child: Text(context.t('common.details'))) : null),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(context.t('dash.fairness_help'), style: theme.textTheme.bodySmall),
                      for (final f in fairness) ...[
                        const Divider(height: 20),
                        Row(children: [
                          Expanded(child: Text(context.code('demo', f['attribute'] as String?), style: theme.textTheme.titleSmall)),
                          Pill(
                            label: f['status'] == 'ok'
                                ? context.t('dash.fair_ok')
                                : f['status'] == 'check'
                                    ? context.t('dash.fair_check')
                                    : context.t('dash.not_enough'),
                            color: f['status'] == 'ok' ? Brand.success : (f['status'] == 'check' ? Brand.danger : Brand.muted),
                            dense: true,
                          ),
                        ]),
                        for (final g in (f['groups'] as List).map((e) => Map<String, dynamic>.from(e as Map)))
                          KeyValue(
                            '${context.code('demo.${f['attribute']}', g['group'] as String?, fallback: g['group'] as String?)} (${context.digits(g['n'])})',
                            '${context.pct(g['approval_rate'] as num?)} · ${context.t('dash.ratio')} ${context.num0(g['disparate_impact'] as num?, digits: 2)}',
                          ),
                      ],
                    ]),
                  ),
                ),
                SectionTitle(context.t('dash.drift')),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: Text(context.t('dash.drift_help'), style: theme.textTheme.bodySmall)),
                        Pill(
                            label: context.code('drift', drift['status'] as String?),
                            color: switch (drift['status']) {
                              'stable' => Brand.success,
                              'moderate shift' => Brand.warning,
                              'major shift' => Brand.danger,
                              _ => Brand.muted,
                            },
                            dense: true),
                      ]),
                      for (final f in (drift['features'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)))
                        KeyValue(context.field(f['feature'] as String), 'PSI ${context.num0(f['psi'] as num?, digits: 3)}'),
                      if (drift['retrain_suggested'] == true)
                        Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(context.t('dash.retrain'), style: theme.textTheme.bodySmall?.copyWith(color: Brand.danger))),
                    ]),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  void _fairness(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const FractionallySizedBox(heightFactor: 0.8, child: _FairnessSheet()),
    );
  }
}

class _FairnessSheet extends ConsumerWidget {
  const _FairnessSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(fairnessProvider);
    final theme = Theme.of(context);
    return AsyncView<Map<String, dynamic>>(
      value: data,
      onRetry: () => ref.invalidate(fairnessProvider),
      builder: (d) {
        final o = Map<String, dynamic>.from(d['overrides'] as Map);
        final officers = (d['officers'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        return ListView(padding: const EdgeInsets.fromLTRB(20, 0, 20, 24), children: [
          Text(context.t('fair.title'), style: theme.textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(context.t('fair.body', {'share': context.pct(d['disclosed_share'] as num?)}), style: theme.textTheme.bodySmall),
          SectionTitle(context.t('fair.overrides')),
          KeyValue(context.t('fair.approved_low'), context.digits(o['approved_low_odds'])),
          KeyValue(context.t('fair.rejected_good'), context.digits(o['rejected_good_odds'])),
          KeyValue(context.t('fair.followed'), context.digits(o['followed'])),
          SectionTitle(context.t('fair.officers')),
          for (final r in officers)
            KeyValue(r['officer'] as String,
                '${context.digits(r['decided'])} · ${context.t('fair.approved_n', {'n': context.digits(r['approved'])})} · ${context.t('fair.override_n', {'n': context.digits(r['overrides'])})}'),
        ]);
      },
    );
  }
}

class PortfolioScreen extends ConsumerWidget {
  const PortfolioScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(portfolioProvider);
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: AsyncView<Map<String, dynamic>>(
          value: data,
          onRetry: () => ref.invalidate(portfolioProvider),
          builder: (d) {
            final p = Map<String, dynamic>.from(d['summary'] as Map);
            final cur = (p['currency'] as String?) ?? 'BDT';
            final loans = Map<String, dynamic>.from(p['loans'] as Map);
            final active = (d['loans'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
            return PageList(
              width: 1100,
              onRefresh: () async => ref.invalidate(portfolioProvider),
              children: [
                PageHeader(title: context.t('port.title'), subtitle: context.t('port.subtitle')),
                Wrap(spacing: 12, runSpacing: 12, children: [
                  StatCard(label: context.t('port.active'), value: context.digits(loans['active']), icon: Icons.account_balance_wallet_outlined,
                      caption: context.t('port.closed', {'n': context.digits(loans['closed'])})),
                  StatCard(label: context.t('port.disbursed'), value: context.money(p['disbursed'] as num?, currency: cur), icon: Icons.payments_outlined),
                  StatCard(label: context.t('port.outstanding'), value: context.money(p['outstanding'] as num?, currency: cur), icon: Icons.hourglass_bottom, color: Brand.info),
                  StatCard(
                      label: context.t('port.on_time'),
                      value: context.pct(p['on_time_rate'] as num?),
                      icon: Icons.verified_outlined,
                      color: Brand.success,
                      caption: context.t('port.installments', {'n': context.digits(p['installments_due'])})),
                  StatCard(
                      label: context.t('port.arrears'),
                      value: context.money(p['arrears'] as num?, currency: cur),
                      icon: Icons.warning_amber_rounded,
                      color: Brand.danger,
                      caption: context.t('port.late_missed', {'late': context.digits(p['late']), 'missed': context.digits(p['missed'])})),
                ]),
                SectionTitle(context.t('port.ladder')),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: BarBreakdown(rows: [
                      for (final l in (p['ladder_mix'] as List).map((e) => Map<String, dynamic>.from(e as Map)))
                        ('L${l['level']} ${context.code('ladder', l['name'] as String?)}', l['borrowers'] as num, Brand.info),
                    ]),
                  ),
                ),
                SectionTitle(context.t('port.loans')),
                if (active.isEmpty) EmptyState(icon: Icons.account_balance_wallet_outlined, title: context.t('port.none')),
                for (final l in active)
                  Card(
                    child: ListTile(
                      title: Text(l['borrower_name'] as String? ?? '-'),
                      subtitle: Text(
                          '${context.money(l['principal'] as num?, currency: cur)} · ${context.t('loans.progress', {'paid': context.digits(l['installments_paid']), 'total': context.digits(l['installments']), 'left': context.money(l['outstanding'] as num?, currency: cur)})}'),
                      trailing: (l['overdue'] as List).isNotEmpty
                          ? Pill(label: context.t('loans.overdue'), color: Brand.danger, dense: true)
                          : Text(context.date((l['next_due'] as Map?)?['due_date'] as String?), style: theme.textTheme.bodySmall),
                      onTap: () => context.go('/staff/applications/${l['application_id']}'),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
