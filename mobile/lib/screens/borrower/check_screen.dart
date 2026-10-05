import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../models/field_spec.dart';
import '../../widgets/account_menu.dart';
import '../../widgets/common.dart';
import '../../widgets/field_input.dart';
import 'readiness_screen.dart';

/// Groups the loan inputs into sections that read naturally on a phone.
const _sections = <String, List<String>>{
  'Your loan': ['LoanAmount', 'LoanTerm', 'InterestRate', 'LoanPurpose', 'HasCoSigner'],
  'Your finances': ['Income', 'CreditScore', 'DTIRatio', 'NumCreditLines', 'HasMortgage'],
  'About you': ['Education', 'EmploymentType', 'MonthsEmployed', 'MaritalStatus', 'HasDependents'],
};

class CheckScreen extends StatefulWidget {
  /// True inside the borrower shell (shows the account menu, no back button).
  final bool embedded;

  /// Called after the borrower successfully applies to a lender.
  final VoidCallback? onApplied;

  const CheckScreen({super.key, this.embedded = false, this.onApplied});

  @override
  State<CheckScreen> createState() => _CheckScreenState();
}

class _CheckScreenState extends State<CheckScreen> {
  Future<ModelMetadata>? _meta;
  final Map<String, Object> _values = {};
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _meta ??= _load();
  }

  Future<ModelMetadata> _load() async {
    final json = await AppScope.read(context).api.get('/metadata') as Map<String, dynamic>;
    final meta = ModelMetadata.fromJson(json);
    if (_values.isEmpty) {
      for (final f in meta.fields) {
        final def = f.defaultValue;
        _values[f.name] =
            (f.hasOptions && !f.options.contains(def)) ? f.options.first : (def ?? f.min ?? 0);
      }
    }
    return meta;
  }

  void _retry() {
    setState(() {
      _meta = _load();
    });
  }

  Future<void> _check() async {
    setState(() => _busy = true);
    final session = AppScope.read(context);
    try {
      final result =
          await session.api.post('/readiness', Map<String, Object>.of(_values)) as Map<String, dynamic>;
      if (!mounted) return;
      final outcome = await Navigator.of(context).push<ReadinessOutcome>(MaterialPageRoute(
        builder: (_) => ReadinessScreen(inputs: Map<String, Object>.of(_values), result: result),
      ));
      if (!mounted || outcome == null) return;
      if (outcome.applied) {
        if (widget.onApplied != null) {
          widget.onApplied!();
        } else {
          // Started logged-out from the welcome screen: go to the borrower home.
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
      } else if (outcome.changes.isNotEmpty) {
        setState(() => _values.addAll(outcome.changes));
        await _check(); // re-check with the borrower's chosen improvement
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Loan readiness check'),
        automaticallyImplyLeading: !widget.embedded,
        actions: [if (widget.embedded) const AccountMenu()],
      ),
      body: FutureBuilder<ModelMetadata>(
        future: _meta,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError || !snap.hasData) {
            return ErrorRetry(error: snap.error ?? 'No data from the server.', onRetry: _retry);
          }
          return _form(snap.data!);
        },
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: FilledButton.icon(
          key: const Key('run-check'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: _busy || _values.isEmpty ? null : _check,
          icon: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.speed),
          label: const Text('Check my readiness'),
        ),
      ),
    );
  }

  Widget _form(ModelMetadata meta) {
    final byName = {for (final f in meta.fields) f.name: f};
    final listed = _sections.values.expand((v) => v).toSet();
    final sections = <String, List<FieldSpec>>{
      for (final e in _sections.entries)
        e.key: [for (final n in e.value) if (byName[n] != null) byName[n]!],
      'Other': [for (final f in meta.fields) if (!listed.contains(f.name)) f],
    }..removeWhere((_, v) => v.isEmpty);

    return MaxWidth(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Text(
            'Answer a few questions. Nothing is saved unless you choose to apply.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          for (final entry in sections.entries)
            Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(entry.key, style: Theme.of(context).textTheme.titleMedium),
                    for (final f in entry.value)
                      FieldInput(
                        spec: f,
                        value: _values[f.name]!,
                        onChanged: (v) => setState(() => _values[f.name] = v),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
