import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import '../../widgets/risk_gauge.dart';
import '../auth/login_screen.dart';

/// What the borrower chose on the result screen.
class ReadinessOutcome {
  final Map<String, Object> changes; // try these changes and re-check
  final bool applied;                // or: they applied to a lender

  const ReadinessOutcome.changes(this.changes) : applied = false;
  const ReadinessOutcome.applied() : changes = const {}, applied = true;
}

class ReadinessScreen extends StatelessWidget {
  final Map<String, Object> inputs;
  final Map<String, dynamic> result;

  const ReadinessScreen({super.key, required this.inputs, required this.result});

  List<Map<String, dynamic>> get _tips =>
      (result['tips'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();

  Map<String, dynamic>? get _plan => result['plan'] as Map<String, dynamic>?;

  static Map<String, Object> _changeOf(Map<String, dynamic> tip) =>
      Map<String, Object>.from(tip['change'] as Map);

  Future<void> _startApply(BuildContext context) async {
    final session = AppScope.read(context);
    if (!session.loggedIn) {
      await Navigator.of(context).push<bool>(
          MaterialPageRoute(builder: (_) => const LoginScreen(returnOnSuccess: true)));
      if (!context.mounted || !session.loggedIn) return;
    }
    if (session.role != 'borrower') {
      showInfo(context, 'Only borrower accounts can apply for loans.');
      return;
    }
    final lender = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ApplySheet(inputs: inputs),
    );
    if (lender != null && context.mounted) {
      showInfo(context, 'Application sent to $lender. Track it under My applications.');
      Navigator.of(context).pop(const ReadinessOutcome.applied());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final light = result['light'] as String?;
    final style = lightStyle(light);
    final prob = (result['default_probability'] as num).toDouble();
    final afford = result['affordability'] as Map<String, dynamic>;

    return Scaffold(
      appBar: AppBar(title: const Text('Your result')),
      body: MaxWidth(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              color: style.color.withValues(alpha: 0.10),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Icon(style.icon, color: style.color, size: 48),
                    const SizedBox(height: 8),
                    Text(result['title'] as String,
                        key: const Key('light-title'),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall
                            ?.copyWith(color: style.color, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 6),
                    Text(result['message'] as String, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    RiskGauge(probability: prob, color: style.color, size: 130),
                  ],
                ),
              ),
            ),
            if (_tips.isNotEmpty) ...[
              const SectionTitle('What you can change'),
              for (final t in _tips)
                Card(
                  child: ListTile(
                    leading: LightBadge(light: t['new_light'] as String?, compact: true),
                    title: Text(t['text'] as String),
                    subtitle: Text('Lowers your risk by ${t['points_lower']} points '
                        '(to ${pct(t['new_probability'] as num)})'),
                    trailing: TextButton(
                      onPressed: () =>
                          Navigator.of(context).pop(ReadinessOutcome.changes(_changeOf(t))),
                      child: const Text('Try it'),
                    ),
                  ),
                ),
            ],
            if (_plan != null) ...[
              const SectionTitle('Best combined plan'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final step in (_plan!['steps'] as List<dynamic>))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.check, size: 18),
                              const SizedBox(width: 8),
                              Expanded(child: Text('$step')),
                            ],
                          ),
                        ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const Text('Result: '),
                          LightBadge(light: _plan!['new_light'] as String?),
                          const SizedBox(width: 8),
                          Text('${pct(_plan!['new_probability'] as num)} risk'),
                        ],
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton(
                        onPressed: () {
                          final merged = <String, Object>{};
                          for (final t in _tips.take(3)) {
                            merged.addAll(_changeOf(t));
                          }
                          Navigator.of(context).pop(ReadinessOutcome.changes(merged));
                        },
                        child: const Text('Apply all these changes'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SectionTitle('Can you afford it?'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${money(afford['monthly_payment'] as num)} per month',
                        style: theme.textTheme.titleLarge),
                    const SizedBox(height: 4),
                    Text('${pct(afford['income_share'] as num, 0)} of your income · '
                        'total interest ${money(afford['total_interest'] as num)}'),
                    const SizedBox(height: 8),
                    Text(afford['note'] as String,
                        style: TextStyle(
                            color: switch (afford['level']) {
                              'comfortable' => const Color(0xFF16A34A),
                              'stretched' => const Color(0xFFD97706),
                              _ => const Color(0xFFDC2626),
                            },
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              key: const Key('apply'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              icon: const Icon(Icons.send),
              label: const Text('Apply to a lender'),
              onPressed: () => _startApply(context),
            ),
            const SizedBox(height: 12),
            Text(
              'Educational guide based on a model trained on public synthetic data. '
              'It is not a lending decision; lenders make the final call.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// Pick a lender, give consent, submit. Pops with the lender's name on success.
class _ApplySheet extends StatefulWidget {
  final Map<String, Object> inputs;

  const _ApplySheet({required this.inputs});

  @override
  State<_ApplySheet> createState() => _ApplySheetState();
}

class _ApplySheetState extends State<_ApplySheet> {
  Map<String, dynamic>? _lender;
  bool _consent = false;
  bool _busy = false;

  Future<List<Map<String, dynamic>>> _loadLenders() async {
    final list = await AppScope.read(context).api.get('/lenders') as List<dynamic>;
    return list.cast<Map<String, dynamic>>();
  }

  Future<void> _submit() async {
    final lender = _lender;
    if (lender == null) return;
    setState(() => _busy = true);
    try {
      await AppScope.read(context).api.post('/applications', {
        'org_id': lender['id'],
        'inputs': widget.inputs,
        'consent': _consent,
      });
      if (mounted) Navigator.of(context).pop(lender['name'] as String);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: 460,
        child: Loader<List<Map<String, dynamic>>>(
          load: _loadLenders,
          builder: (context, lenders, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Choose a lender', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Expanded(
                child: ListView(
                  children: [
                    for (final l in lenders)
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.account_balance),
                          title: Text(l['name'] as String),
                          selected: _lender?['id'] == l['id'],
                          trailing: _lender?['id'] == l['id'] ? const Icon(Icons.check_circle) : null,
                          onTap: () => setState(() => _lender = l),
                        ),
                      ),
                  ],
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _consent,
                onChanged: (v) => setState(() => _consent = v ?? false),
                title: const Text('I agree to share these details with the selected lender.'),
              ),
              FilledButton(
                key: const Key('submit-application'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                onPressed: _lender == null || !_consent || _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Send application'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
