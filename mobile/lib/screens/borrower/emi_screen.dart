import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../widgets/account_menu.dart';
import '../../widgets/common.dart';

/// Equal monthly instalment, same formula as the API's /emi endpoint.
double emi(double principal, double annualRatePct, int months) {
  final r = annualRatePct / 100 / 12;
  if (r == 0) return principal / months;
  final f = math.pow(1 + r, months).toDouble();
  return principal * r * f / (f - 1);
}

class EmiScreen extends StatefulWidget {
  const EmiScreen({super.key});

  @override
  State<EmiScreen> createState() => _EmiScreenState();
}

class _EmiScreenState extends State<EmiScreen> {
  double _amount = 50000;
  double _rate = 12;
  int _months = 36;
  double _income = 60000;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final monthly = emi(_amount, _rate, _months);
    final share = monthly * 12 / _income;
    final (Color color, String note) = share <= 0.30
        ? (const Color(0xFF16A34A), 'Comfortable')
        : share <= 0.40
            ? (const Color(0xFFD97706), 'Stretched')
            : (const Color(0xFFDC2626), 'Risky: over 40% of income');

    Widget slider(String label, String shown, double value, double min, double max, int divisions,
            ValueChanged<double> onChanged) =>
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(child: Text(label)),
              Text(shown, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
            ]),
            Slider(value: value, min: min, max: max, divisions: divisions, onChanged: onChanged),
          ],
        );

    return Scaffold(
      appBar: AppBar(title: const Text('EMI calculator'), actions: const [AccountMenu()]),
      body: MaxWidth(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Text('Monthly payment', style: theme.textTheme.bodyMedium),
                    Text(money(monthly),
                        key: const Key('emi-value'),
                        style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Text('${pct(share, 0)} of income · $note',
                        style: TextStyle(color: color, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Text('Total interest ${money(monthly * _months - _amount)}',
                        style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Column(
                  children: [
                    slider('Loan amount', money(_amount), _amount, 5000, 250000, 245,
                        (v) => setState(() => _amount = v)),
                    slider('Interest rate', '${_rate.toStringAsFixed(1)}%', _rate, 2, 25, 230,
                        (v) => setState(() => _rate = v)),
                    slider('Term', '$_months months', _months.toDouble(), 6, 120, 19,
                        (v) => setState(() => _months = v.round())),
                    slider('Annual income', money(_income), _income, 15000, 150000, 135,
                        (v) => setState(() => _income = v)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
