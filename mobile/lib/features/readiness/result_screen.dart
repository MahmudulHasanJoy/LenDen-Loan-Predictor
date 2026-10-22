import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/session.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/theme.dart';
import '../../shared/models/metadata.dart';
import '../../shared/widgets/common.dart';
import '../../shared/widgets/explain.dart';
import '../../shared/widgets/field_input.dart';
import '../../shared/widgets/odds.dart';
import 'draft_controller.dart';

/// Instant estimate + live simulator. Sliders call /simulate (debounced); the last good answer
/// stays on screen while the next one loads, so numbers never flash empty.
class ResultScreen extends ConsumerStatefulWidget {
  const ResultScreen({super.key});

  @override
  ConsumerState<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends ConsumerState<ResultScreen> {
  static const sliders = ['LoanAmount', 'LoanTerm', 'HasCoSigner', 'DTIRatio'];
  final Map<String, Object> _overrides = {};
  Map<String, dynamic>? _result;
  Object? _error;
  bool _loading = false;
  Timer? _debounce;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      await ref.read(draftProvider.notifier).ensure();
      _simulate();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _change(String field, Object value) {
    setState(() => _overrides[field] = value);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), _simulate);
  }

  Future<void> _simulate() async {
    final draft = ref.read(draftProvider);
    if (draft.id == null) return;
    final seq = ++_seq;
    setState(() => _loading = true);
    try {
      final res = await ref.read(apiProvider).post('/simulate', {
        'draft_id': draft.id,
        'inputs': draft.inputs,
        'overrides': _overrides,
      }) as Map<String, dynamic>;
      if (!mounted || seq != _seq) return;          // a newer request is on its way
      setState(() {
        _result = res;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  void _applyNextStep(Map<String, dynamic> step) {
    for (final c in (step['changes'] as List)) {
      final m = Map<String, dynamic>.from(c as Map);
      _overrides[m['feature'] as String] = m['to'] as Object;
    }
    setState(() {});
    _simulate();
  }

  Future<void> _useAndContinue() async {
    if (_overrides.isNotEmpty) await ref.read(draftProvider.notifier).setMany(Map.of(_overrides));
    if (mounted) context.go('/offers');
  }

  @override
  Widget build(BuildContext context) {
    final meta = ref.watch(metadataProvider);
    final draft = ref.watch(draftProvider);
    final theme = Theme.of(context);
    final r = _result;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => context.go('/check?step=2')),
        title: Text(context.t('result.appbar')),
      ),
      body: AsyncView<ModelMetadata>(
        value: meta,
        onRetry: () => ref.invalidate(metadataProvider),
        builder: (m) {
          if (r == null) {
            return _error != null
                ? ErrorRetry(error: _error!, onRetry: _simulate)
                : const Center(child: CircularProgressIndicator());
          }
          final inputs = Map<String, dynamic>.from(r['inputs'] as Map);
          final estimated = (r['estimated_fields'] as List? ?? const []).length;
          return PageList(width: 680, children: [
            AnimatedOpacity(
              opacity: _loading ? 0.6 : 1,
              duration: const Duration(milliseconds: 150),
              child: OddsHero(
                odds: r['odds'] as String,
                caption: estimated > 0 ? context.t('result.estimated', {'n': context.digits(estimated)}) : null,
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  IconTile(icon: Icons.calendar_month_outlined, color: theme.colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(context.t('result.monthly'), style: theme.textTheme.bodySmall),
                      Text(context.money(r['emi'] as num?), style: theme.textTheme.titleLarge),
                    ]),
                  ),
                  Pill(
                    label: context.code('afford', r['affordability'] as String?),
                    color: switch (r['affordability']) {
                      'comfortable' => Brand.success,
                      'stretched' => Brand.warning,
                      _ => Brand.danger,
                    },
                  ),
                ]),
              ),
            ),
            if ((r['reasons'] as List).isNotEmpty && r['odds'] != 'excellent')
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: ReasonList(
                      title: context.t('result.why'), codes: (r['reasons'] as List).map((e) => e.toString()).toList()),
                ),
              ),
            NextStepCard(
              step: r['next_step'] == null ? null : Map<String, dynamic>.from(r['next_step'] as Map),
              onApply: r['next_step'] == null
                  ? null
                  : () => _applyNextStep(Map<String, dynamic>.from(r['next_step'] as Map)),
            ),
            SectionTitle(context.t('result.simulator'), trailing: _overrides.isEmpty
                ? null
                : TextButton(
                    onPressed: () {
                      setState(_overrides.clear);
                      _simulate();
                    },
                    child: Text(context.t('result.reset')))),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Column(children: [
                  for (final name in sliders)
                    if (m.field(name) != null)
                      FieldInput(
                        key: ValueKey('sim-$name'),
                        spec: m.field(name)!,
                        value: _overrides[name] ?? inputs[name] ?? m.field(name)!.defaultValue!,
                        onChanged: (v) => _change(name, v),
                      ),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: draft.saving ? null : _useAndContinue,
              icon: const Icon(Icons.storefront_outlined),
              label: Text(_overrides.isEmpty ? context.t('result.see_offers') : context.t('result.use_and_see')),
            ),
            const SizedBox(height: 8),
            Text(context.t('result.disclaimer'), style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
          ]);
        },
      ),
    );
  }
}
