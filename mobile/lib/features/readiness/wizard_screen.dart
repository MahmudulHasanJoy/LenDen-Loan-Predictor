import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n/l10n.dart';
import '../../core/theme/theme.dart';
import '../../shared/models/metadata.dart';
import '../../shared/widgets/common.dart';
import '../../shared/widgets/field_input.dart';
import '../../shared/widgets/progress.dart';
import 'draft_controller.dart';

/// The 4-step loan check. Steps 1-2 are the quick check (six questions), step 3 the full
/// profile, step 4 optional questions used only for fairness monitoring. Every change autosaves.
class WizardScreen extends ConsumerStatefulWidget {
  final int? startStep;
  const WizardScreen({super.key, this.startStep});

  @override
  ConsumerState<WizardScreen> createState() => _WizardScreenState();
}

class _WizardScreenState extends ConsumerState<WizardScreen> {
  int? _step;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      await ref.read(draftProvider.notifier).ensure();
      if (!mounted) return;
      final saved = ref.read(draftProvider).step;
      setState(() => _step = (widget.startStep ?? (saved > 2 ? saved : 1)).clamp(1, 4).toInt());
    });
  }

  List<String> _titles(BuildContext context) =>
      [context.t('wizard.title1'), context.t('wizard.title2'), context.t('wizard.title3'), context.t('wizard.title4')];

  Future<void> _next(ModelMetadata meta) async {
    final draft = ref.read(draftProvider.notifier);
    final step = _step!;
    // Keep the values shown on screen (defaults the user accepted count as answers).
    final values = <String, Object>{};
    for (final f in meta.steps[step] ?? const <String>[]) {
      final v = ref.read(draftProvider).inputs[f] ?? meta.field(f)?.defaultValue;
      if (v != null) values[f] = v;
    }
    if (values.isNotEmpty) await draft.setMany(values);
    if (step == 2) {
      await draft.goToStep(3);
      if (mounted) context.go('/check/result');
      return;
    }
    if (step == 4) {
      await draft.goToStep(4);
      if (mounted) context.go('/offers');
      return;
    }
    await draft.goToStep(step + 1);
    setState(() => _step = step + 1);
  }

  void _back() {
    final step = _step!;
    if (step == 1) {
      context.canPop() ? context.pop() : context.go('/');
    } else {
      setState(() => _step = step - 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final meta = ref.watch(metadataProvider);
    final draft = ref.watch(draftProvider);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: _step == null ? null : _back),
        title: Text(context.t('wizard.appbar')),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                draft.saving ? context.t('wizard.saving') : (draft.savedAt != null ? context.t('wizard.saved') : ''),
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
        ],
      ),
      body: AsyncView<ModelMetadata>(
        value: meta,
        onRetry: () => ref.invalidate(metadataProvider),
        builder: (m) {
          if (draft.error != null && draft.id == null) {
            return ErrorRetry(error: draft.error!, onRetry: () => ref.read(draftProvider.notifier).ensure());
          }
          if (_step == null || draft.id == null) return const Center(child: CircularProgressIndicator());
          final step = _step!;
          return Column(children: [
            Expanded(
              child: PageList(width: 640, children: [
                StepProgress(step: step, total: 4, labels: _titles(context)),
                const SizedBox(height: 4),
                Text(context.t('wizard.sub$step'), style: theme.textTheme.bodyMedium?.copyWith(color: Brand.muted)),
                const SizedBox(height: 12),
                if (step < 4)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: Column(children: [
                        for (final name in m.steps[step] ?? const <String>[])
                          if (m.field(name) != null)
                            FieldInput(
                              key: ValueKey('f-$name'),
                              spec: m.field(name)!,
                              value: draft.inputs[name] ?? m.field(name)!.defaultValue!,
                              onChanged: (v) => ref.read(draftProvider.notifier).set(name, v),
                            ),
                      ]),
                    ),
                  )
                else
                  _OptionalProfile(meta: m),
                if (draft.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(errorText(context, draft.error!), style: TextStyle(color: theme.colorScheme.error)),
                  ),
                const SizedBox(height: 8),
                Row(children: [
                  const Icon(Icons.lock_outline, size: 16, color: Brand.muted),
                  const SizedBox(width: 6),
                  Expanded(child: Text(context.t('wizard.privacy'), style: theme.textTheme.bodySmall)),
                ]),
              ]),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: MaxWidth(
                  width: 640,
                  child: Row(children: [
                    OutlinedButton(onPressed: _back, child: Text(context.t('common.back'))),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: draft.saving ? null : () => _next(m),
                        child: Text(step == 2
                            ? context.t('wizard.see_result')
                            : step == 4
                                ? context.t('wizard.see_offers')
                                : context.t('common.next')),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ]);
        },
      ),
    );
  }
}

/// Step 4: optional, self-reported answers used only to check that decisions are fair.
class _OptionalProfile extends ConsumerWidget {
  final ModelMetadata meta;
  const _OptionalProfile({required this.meta});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(draftProvider);
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.balance_outlined, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(child: Text(context.t('wizard.fairness_title'), style: theme.textTheme.titleMedium)),
          ]),
          const SizedBox(height: 6),
          Text(context.t('wizard.fairness_body'), style: theme.textTheme.bodySmall),
          for (final entry in meta.demographics.entries) ...[
            const SizedBox(height: 16),
            Text(context.code('demo', entry.key), style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final option in entry.value)
                ChoiceChip(
                  label: Text(context.code('demo.${entry.key}', option, fallback: option)),
                  selected: draft.demographics[entry.key] == option,
                  onSelected: (_) => ref.read(draftProvider.notifier).setDemographic(entry.key, option),
                ),
            ]),
          ],
        ]),
      ),
    );
  }
}
