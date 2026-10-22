import 'package:flutter/material.dart';

import '../../core/l10n/l10n.dart';
import '../../core/theme/theme.dart';
import 'common.dart';
import 'odds.dart';

/// Plain-language reasons from stable codes (e.g. DTI_HIGH).
class ReasonList extends StatelessWidget {
  final List<String> codes;
  final String? title;

  const ReasonList({super.key, required this.codes, this.title});

  @override
  Widget build(BuildContext context) {
    if (codes.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (title != null) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(title!, style: theme.textTheme.titleSmall)),
      for (final c in codes)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Padding(padding: EdgeInsets.only(top: 2), child: Icon(Icons.info_outline, size: 18, color: Brand.warning)),
            const SizedBox(width: 8),
            Expanded(child: Text(context.code('reason', c), style: theme.textTheme.bodyMedium)),
          ]),
        ),
    ]);
  }
}

/// One change, e.g. "Borrow ৳48,000 instead of ৳1,20,000".
String describeChange(BuildContext context, Map<String, dynamic> c, {String currency = 'BDT'}) {
  final feature = c['feature'] as String;
  return context.t('change.${c['code']}', {
    'from': context.value(feature, c['from'], currency: currency),
    'to': context.value(feature, c['to'], currency: currency),
  });
}

/// "The smallest change that would improve your odds" with an optional "try it" action.
class NextStepCard extends StatelessWidget {
  final Map<String, dynamic>? step;
  final VoidCallback? onApply;
  final String currency;

  const NextStepCard({super.key, required this.step, this.onApply, this.currency = 'BDT'});

  @override
  Widget build(BuildContext context) {
    final s = step;
    if (s == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final changes = (s['changes'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    return Card(
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.lightbulb_outline, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(child: Text(context.t('next.title'), style: theme.textTheme.titleMedium)),
          ]),
          const SizedBox(height: 8),
          for (final c in changes)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                const Icon(Icons.arrow_right_alt, size: 20),
                const SizedBox(width: 6),
                Expanded(child: Text(describeChange(context, c, currency: currency))),
              ]),
            ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text(context.t('next.result'), style: theme.textTheme.bodySmall),
            OddsChip(odds: s['odds'] as String?, dense: true),
          ]),
          if (onApply != null) ...[
            const SizedBox(height: 10),
            FilledButton.tonalIcon(onPressed: onApply, icon: const Icon(Icons.tune), label: Text(context.t('next.try'))),
          ],
        ]),
      ),
    );
  }
}

/// One lender's estimated offer.
class OfferCard extends StatelessWidget {
  final Map<String, dynamic> offer;
  final VoidCallback? onApply;
  final bool highlight;

  const OfferCard({super.key, required this.offer, this.onApply, this.highlight = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cur = (offer['currency'] as String?) ?? 'BDT';
    final best = Map<String, dynamic>.from(offer['best'] as Map);
    final eligible = offer['eligible'] == true;
    final hours = offer['typical_decision_hours'] as num?;
    final policy = (offer['policy'] as List? ?? const []).map((e) => e.toString()).toList();
    return Card(
      shape: highlight
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Space.radius), side: BorderSide(color: theme.colorScheme.primary, width: 1.6))
          : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            IconTile(icon: Icons.account_balance_outlined, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(offer['lender'] as String? ?? '', style: theme.textTheme.titleMedium),
                if (hours != null)
                  Text(context.t('offers.decision_time', {'hours': context.num0(hours)}), style: theme.textTheme.bodySmall),
              ]),
            ),
            OddsChip(odds: best['odds'] as String?, dense: true),
          ]),
          const Divider(height: 24),
          if (eligible) ...[
            Text(context.t('offers.range'), style: theme.textTheme.bodySmall),
            Text('${context.money(offer['amount_min'] as num?, currency: cur)} - ${context.money(offer['amount_max'] as num?, currency: cur)}',
                style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
          ],
          Wrap(spacing: 18, runSpacing: 8, children: [
            _Fact(context.t('offers.best_amount'), context.money(best['amount'] as num?, currency: cur)),
            _Fact(context.t('offers.term'), context.t('common.months', {'n': context.digits(best['term'])})),
            _Fact(context.t('offers.rate'), context.t('common.rate_pa', {'rate': context.num0(best['rate'] as num?, digits: 1)})),
            _Fact(context.t('offers.emi'), context.money(best['emi'] as num?, currency: cur)),
          ]),
          if (offer['capped_by_ladder'] == true)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(children: [
                const Icon(Icons.stairs_outlined, size: 18, color: Brand.info),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                      context.t('offers.ladder_cap', {
                        'level': context.digits(offer['ladder_level']),
                        'cap': context.money(offer['ladder_cap'] as num?, currency: cur)
                      }),
                      style: theme.textTheme.bodySmall),
                ),
              ]),
            ),
          if (policy.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 10), child: ReasonList(codes: policy)),
          if (!eligible && policy.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(context.t('offers.not_eligible'), style: theme.textTheme.bodySmall),
            ),
          if (offer['has_open_application'] == true)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(context.t('offers.already_applied'), style: theme.textTheme.bodySmall?.copyWith(color: Brand.info)),
            )
          else if (onApply != null) ...[
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: eligible
                  ? FilledButton(onPressed: onApply, child: Text(context.t('offers.apply')))
                  : OutlinedButton(onPressed: onApply, child: Text(context.t('offers.apply_anyway'))),
            ),
          ],
        ]),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  final String label;
  final String value;
  const _Fact(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: theme.textTheme.bodySmall),
      Text(value, style: theme.textTheme.titleSmall),
    ]);
  }
}
