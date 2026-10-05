import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';

const _labels = {
  'Income': 'Annual income',
  'LoanAmount': 'Loan amount',
  'CreditScore': 'Credit score',
  'MonthsEmployed': 'Months employed',
  'NumCreditLines': 'Open credit lines',
  'InterestRate': 'Interest rate',
  'LoanTerm': 'Loan term (months)',
  'DTIRatio': 'Debt-to-income ratio',
  'Education': 'Education',
  'EmploymentType': 'Employment type',
  'MaritalStatus': 'Marital status',
  'HasMortgage': 'Has a mortgage',
  'HasDependents': 'Has dependents',
  'LoanPurpose': 'Loan purpose',
  'HasCoSigner': 'Has a co-signer',
};

/// Full application for the officer: model recommendation, reasons, inputs and the human decision.
class ApplicationDetailScreen extends StatefulWidget {
  final int applicationId;

  const ApplicationDetailScreen({super.key, required this.applicationId});

  @override
  State<ApplicationDetailScreen> createState() => _ApplicationDetailScreenState();
}

class _ApplicationDetailScreenState extends State<ApplicationDetailScreen> {
  bool _changed = false;
  int _version = 0;

  Future<Map<String, dynamic>> _load() async =>
      await AppScope.read(context).api.get('/org/applications/${widget.applicationId}')
          as Map<String, dynamic>;

  Future<void> _decide(String decision) async {
    final note = await showDialog<String>(
      context: context,
      builder: (_) => _NoteDialog(decision: decision),
    );
    if (note == null || !mounted) return;
    try {
      await AppScope.read(context).api.post(
          '/org/applications/${widget.applicationId}/decision', {'decision': decision, 'note': note});
      if (!mounted) return;
      showInfo(context, 'Saved: ${statusStyle(decision).label}');
      setState(() {
        _changed = true;
        _version++;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<bool>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        appBar: AppBar(title: Text('Application #${widget.applicationId}')),
        body: Loader<Map<String, dynamic>>(
          key: ValueKey(_version),
          load: _load,
          builder: (context, a, _) => _body(context, a),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, Map<String, dynamic> a) {
    final theme = Theme.of(context);
    final borrower = a['borrower'] as Map<String, dynamic>;
    final reasons = (a['reasons'] as List<dynamic>).cast<Map<String, dynamic>>();
    final inputs = Map<String, dynamic>.from(a['inputs'] as Map);
    final review = a['recommendation'] == 'REVIEW';
    final pending = a['status'] == 'submitted' || a['status'] == 'needs_docs';
    final maxImpact = reasons.isEmpty
        ? 1.0
        : reasons.map((r) => (r['impact'] as num).abs().toDouble()).reduce((x, y) => x > y ? x : y);

    return MaxWidth(
      width: 860,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: CircleAvatar(child: Text((borrower['name'] as String)[0])),
              title: Text(borrower['name'] as String, style: theme.textTheme.titleMedium),
              subtitle: Text('${borrower['email']}\nApplied ${shortDate(a['created_at'] as String?)}'),
              isThreeLine: true,
              trailing: StatusChip(status: a['status'] as String?),
            ),
          ),
          Card(
            color: (review ? const Color(0xFFEA580C) : const Color(0xFF16A34A)).withValues(alpha: 0.08),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 28,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _metric(context, 'Model recommendation', review ? 'REVIEW' : 'APPROVE',
                      color: review ? const Color(0xFFEA580C) : const Color(0xFF16A34A)),
                  _metric(context, 'Default probability', pct(a['default_probability'] as num)),
                  _metric(context, 'Risk score', (a['risk_score'] as num).toStringAsFixed(3)),
                  _metric(context, 'Threshold', (a['threshold'] as num).toStringAsFixed(3)),
                  LightBadge(light: a['light'] as String?),
                ],
              ),
            ),
          ),
          const SectionTitle('Why the model says this'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  for (final r in reasons) _reason(context, r, maxImpact),
                ],
              ),
            ),
          ),
          const SectionTitle('Application details'),
          Card(
            child: Column(
              children: [
                for (final e in inputs.entries)
                  ListTile(
                    dense: true,
                    title: Text(_labels[e.key] ?? e.key),
                    trailing: Text(formatValue(e.key, e.value),
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
              ],
            ),
          ),
          const SectionTitle('Decision'),
          if (pending)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: const Key('approve'),
                  style: FilledButton.styleFrom(backgroundColor: const Color(0xFF16A34A)),
                  onPressed: () => _decide('approved'),
                  icon: const Icon(Icons.check),
                  label: const Text('Approve'),
                ),
                OutlinedButton.icon(
                  onPressed: a['status'] == 'needs_docs' ? null : () => _decide('needs_docs'),
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Ask for documents'),
                ),
                FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: const Color(0xFFDC2626)),
                  onPressed: () => _decide('rejected'),
                  icon: const Icon(Icons.close),
                  label: const Text('Reject'),
                ),
              ],
            )
          else
            Card(
              child: ListTile(
                title: Text('${statusStyle(a['status'] as String?).label} by ${a['decided_by_name'] ?? '-'}'),
                subtitle: Text('${shortDate(a['decided_at'] as String?)}'
                    '${a['decision_note'] != null ? '\n"${a['decision_note']}"' : ''}'),
              ),
            ),
          if (pending && a['decision_note'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('Last note: "${a['decision_note']}"', style: theme.textTheme.bodySmall),
            ),
          const SizedBox(height: 12),
          Text('The model recommends; a person decides. Every decision is recorded in the activity log.',
              style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _metric(BuildContext context, String label, String value, {Color? color}) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: theme.textTheme.bodySmall),
        Text(value,
            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, color: color)),
      ],
    );
  }

  Widget _reason(BuildContext context, Map<String, dynamic> r, double maxImpact) {
    final impact = (r['impact'] as num).toDouble();
    final up = impact > 0;
    final color = up ? const Color(0xFFDC2626) : const Color(0xFF16A34A);
    final feature = r['feature'] as String;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(up ? Icons.arrow_upward : Icons.arrow_downward, size: 16, color: color),
              const SizedBox(width: 6),
              Expanded(child: Text('${r['label']}: ${formatValue(feature, r['value'])}')),
              Text('${up ? '+' : '-'}${(impact.abs() * 100).toStringAsFixed(1)} pts',
                  style: TextStyle(color: color, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: maxImpact == 0 ? 0 : impact.abs() / maxImpact,
              minHeight: 6,
              color: color,
              backgroundColor: color.withValues(alpha: 0.12),
            ),
          ),
          Text('Typical applicant: ${formatValue(feature, r['typical'])}',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _NoteDialog extends StatefulWidget {
  final String decision;

  const _NoteDialog({required this.decision});

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  late final TextEditingController _note = TextEditingController(text: switch (widget.decision) {
    'approved' => 'Approved. We will contact you about next steps.',
    'needs_docs' => 'Please upload your last 3 months of bank statements.',
    _ => '',
  });

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reject = widget.decision == 'rejected';
    return AlertDialog(
      title: Text(switch (widget.decision) {
        'approved' => 'Approve application',
        'needs_docs' => 'Ask for documents',
        _ => 'Reject application',
      }),
      content: TextField(
        controller: _note,
        maxLines: 3,
        autofocus: true,
        decoration: InputDecoration(
          labelText: reject ? 'Reason for the borrower (required)' : 'Message to the borrower',
          border: const OutlineInputBorder(),
        ),
        onChanged: (_) => setState(() {}),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: reject && _note.text.trim().isEmpty
              ? null
              : () => Navigator.pop(context, _note.text.trim()),
          child: const Text('Confirm'),
        ),
      ],
    );
  }
}
