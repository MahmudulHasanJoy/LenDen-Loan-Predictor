import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/l10n/l10n.dart';
import 'common.dart';

/// Approval odds as colour + icon + words (never colour alone).
class OddsChip extends StatelessWidget {
  final String? odds;
  final bool dense;

  const OddsChip({super.key, required this.odds, this.dense = false});

  @override
  Widget build(BuildContext context) {
    final c = oddsColors[odds] ?? Colors.grey;
    return Semantics(
      label: context.t('odds.semantic', {'odds': context.code('odds', odds)}),
      child: Pill(label: context.code('odds', odds), color: c, icon: oddsIcons[odds], dense: dense),
    );
  }
}

/// Big result card: odds label, short explanation and a 4-step meter.
class OddsHero extends StatelessWidget {
  final String odds;
  final String? caption;

  const OddsHero({super.key, required this.odds, this.caption});

  static const _order = ['low', 'fair', 'good', 'excellent'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = oddsColors[odds] ?? Colors.grey;
    final level = _order.indexOf(odds);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(context.t('result.your_odds'), style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Row(children: [
            Icon(oddsIcons[odds], color: c, size: 34),
            const SizedBox(width: 10),
            Expanded(
              child: Text(context.code('odds', odds),
                  style: theme.textTheme.headlineMedium?.copyWith(color: c, fontWeight: FontWeight.w800)),
            ),
          ]),
          const SizedBox(height: 6),
          Text(context.code('odds_copy', odds), style: theme.textTheme.bodyLarge),
          const SizedBox(height: 14),
          Semantics(
            label: context.t('odds.meter', {'n': level + 1}),
            child: Row(children: [
              for (var i = 0; i < 4; i++)
                Expanded(
                  child: Container(
                    height: 8,
                    margin: EdgeInsets.only(right: i < 3 ? 6 : 0),
                    decoration: BoxDecoration(
                      color: i <= level ? c : theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
            ]),
          ),
          if (caption != null) ...[
            const SizedBox(height: 10),
            Text(caption!, style: theme.textTheme.bodySmall),
          ],
        ]),
      ),
    );
  }
}
