import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/session.dart';
import '../../widgets/account_menu.dart';
import '../../widgets/common.dart';

/// Lender admin: the business rules behind the model's APPROVE / REVIEW recommendation.
class OrgSettingsScreen extends StatelessWidget {
  const OrgSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Decision settings'), actions: const [AccountMenu()]),
      body: Loader<Map<String, dynamic>>(
        load: () async => await AppScope.read(context).api.get('/org/settings') as Map<String, dynamic>,
        builder: (context, s, _) => _SettingsForm(initial: s),
      ),
    );
  }
}

class _SettingsForm extends StatefulWidget {
  final Map<String, dynamic> initial;

  const _SettingsForm({required this.initial});

  @override
  State<_SettingsForm> createState() => _SettingsFormState();
}

class _SettingsFormState extends State<_SettingsForm> {
  late int _ratio = widget.initial['cost_ratio'] as int;
  late bool _capOn = widget.initial['review_capacity'] != null;
  late double _cap = ((widget.initial['review_capacity'] as num?) ?? 0.3).toDouble();
  late double _threshold = (widget.initial['recommendation_threshold'] as num).toDouble();
  late final int _maxRatio = widget.initial['max_cost_ratio'] as int;
  bool _busy = false;

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final res = await AppScope.read(context).api.put('/org/settings', {
        'cost_ratio': _ratio,
        if (_capOn) 'review_capacity': double.parse(_cap.toStringAsFixed(2)),
        if (!_capOn) 'clear_capacity': true,
      }) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() => _threshold = (res['recommendation_threshold'] as num).toDouble());
      showInfo(context, 'Saved. New applications use the updated rule.');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final breakEven = 1 / (_ratio + 1);
    return MaxWidth(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Cost of a missed default vs. a manual review', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text('How many times more expensive is approving a borrower who defaults than '
                      'reviewing a good borrower?', style: theme.textTheme.bodySmall),
                  Slider(
                    min: 1,
                    max: _maxRatio.toDouble(),
                    divisions: _maxRatio - 1,
                    value: _ratio.toDouble(),
                    label: '$_ratio:1',
                    onChanged: (v) => setState(() => _ratio = v.round()),
                  ),
                  Text('$_ratio:1 → reviewing pays off when default risk is above ${pct(breakEven)}.'),
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Limit review volume'),
                    subtitle: const Text('Only the riskiest share of applications is recommended for review.'),
                    value: _capOn,
                    onChanged: (v) => setState(() => _capOn = v),
                  ),
                  if (_capOn) ...[
                    Slider(
                      min: 0.05,
                      max: 1,
                      divisions: 19,
                      value: _cap.clamp(0.05, 1.0).toDouble(),
                      label: pct(_cap, 0),
                      onChanged: (v) => setState(() => _cap = v),
                    ),
                    Text('Review at most ${pct(_cap, 0)} of applications. '
                        'In testing, a 30% cap kept about 81% of the possible savings.'),
                  ],
                ],
              ),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.rule),
              title: Text('Current review threshold: ${_threshold.toStringAsFixed(3)}'),
              subtitle: const Text('Risk scores at or above this are recommended for review. '
                  'Officers always make the final decision.'),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
            onPressed: _busy ? null : _save,
            child: const Text('Save settings'),
          ),
        ],
      ),
    );
  }
}
