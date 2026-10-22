import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_client.dart';
import '../../core/auth/session.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/theme.dart';
import '../../shared/widgets/common.dart';
import '../../shared/widgets/explain.dart';
import '../readiness/draft_controller.dart';

final offersProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final id = ref.watch(draftProvider.select((d) => d.id));
  if (id == null) {
    // The screen starts or resumes the draft; this provider runs again when the id arrives.
    return Completer<Map<String, dynamic>>().future;
  }
  return await ref.watch(apiProvider).get('/drafts/$id/offers') as Map<String, dynamic>;
});

/// Compare every lender's estimated offer and apply to one.
class OffersScreen extends ConsumerStatefulWidget {
  const OffersScreen({super.key});

  @override
  ConsumerState<OffersScreen> createState() => _OffersScreenState();
}

class _OffersScreenState extends ConsumerState<OffersScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(draftProvider.notifier).ensure());
  }

  @override
  Widget build(BuildContext context) {
    final offers = ref.watch(offersProvider);
    final session = ref.watch(sessionProvider);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => context.canPop() ? context.pop() : context.go(session.loggedIn ? '/home' : '/check/result')),
        title: Text(context.t('offers.appbar')),
      ),
      body: AsyncView<Map<String, dynamic>>(
        value: offers,
        onRetry: () => ref.invalidate(offersProvider),
        builder: (data) {
          final list = (data['offers'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
          final estimated = (data['estimated_fields'] as List? ?? const []).isNotEmpty;
          final anyEligible = list.any((o) => o['eligible'] == true);
          return PageList(
            width: 720,
            onRefresh: () async => ref.invalidate(offersProvider),
            children: [
              Text(context.t('offers.title'), style: theme.textTheme.headlineSmall),
              const SizedBox(height: 4),
              Text(context.t('offers.subtitle'), style: theme.textTheme.bodyMedium?.copyWith(color: Brand.muted)),
              if (estimated)
                Card(
                  color: Brand.info.withValues(alpha: 0.08),
                  child: ListTile(
                    leading: const Icon(Icons.edit_note, color: Brand.info),
                    title: Text(context.t('offers.finish_profile')),
                    subtitle: Text(context.t('offers.finish_profile_sub')),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.go('/check?step=3'),
                  ),
                ),
              if (!anyEligible)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(context.t('offers.none_eligible'), style: theme.textTheme.bodyMedium),
                ),
              const SizedBox(height: 8),
              for (var i = 0; i < list.length; i++)
                OfferCard(
                  offer: list[i],
                  highlight: i == 0 && list[i]['eligible'] == true,
                  onApply: () => _apply(context, list[i], estimated),
                ),
              if (list.isNotEmpty && list.first['next_step'] != null && !anyEligible)
                NextStepCard(step: Map<String, dynamic>.from(list.first['next_step'] as Map)),
              const SizedBox(height: 8),
              Text(context.t('offers.disclaimer'), style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
            ],
          );
        },
      ),
    );
  }

  void _apply(BuildContext context, Map<String, dynamic> offer, bool estimated) {
    final session = ref.read(sessionProvider);
    if (!session.loggedIn) {
      // The draft is kept and joins the new account automatically.
      context.go('/register?from=/offers');
      return;
    }
    if (estimated) {
      context.go('/check?step=3');
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ApplySheet(offer: offer),
    );
  }
}

/// Review terms, give consent, submit (with an idempotency key so a retry never applies twice).
class ApplySheet extends ConsumerStatefulWidget {
  final Map<String, dynamic> offer;
  const ApplySheet({super.key, required this.offer});

  @override
  ConsumerState<ApplySheet> createState() => _ApplySheetState();
}

class _ApplySheetState extends ConsumerState<ApplySheet> {
  bool _consent = false;
  bool _busy = false;
  final _key = ApiClient.newIdempotencyKey();

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      final res = await ref.read(apiProvider).post('/applications', {
        'offer_id': widget.offer['offer_id'],
        'consent': true,
        'demographics': ref.read(draftProvider).demographics,
      }, _key) as Map<String, dynamic>;
      await ref.read(draftProvider.notifier).reset();
      if (!mounted) return;
      final router = GoRouter.of(context);
      final messenger = ScaffoldMessenger.of(context);
      final message = context.t('apply.sent', {'lender': widget.offer['lender']});
      Navigator.of(context).pop();
      messenger.showSnackBar(SnackBar(content: Text(message)));
      router.go('/applications/${res['id']}');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final best = Map<String, dynamic>.from(widget.offer['best'] as Map);
    final cur = (widget.offer['currency'] as String?) ?? 'BDT';
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(context.t('apply.title', {'lender': widget.offer['lender']}), style: theme.textTheme.titleLarge),
        const SizedBox(height: 12),
        KeyValue(context.t('offers.best_amount'), context.money(best['amount'] as num?, currency: cur), strong: true),
        KeyValue(context.t('offers.term'), context.t('common.months', {'n': context.digits(best['term'])})),
        KeyValue(context.t('offers.rate'), context.t('common.rate_pa', {'rate': context.num0(best['rate'] as num?, digits: 1)})),
        KeyValue(context.t('offers.emi'), context.money(best['emi'] as num?, currency: cur)),
        const SizedBox(height: 8),
        Text(context.t('apply.final_terms'), style: theme.textTheme.bodySmall),
        const Divider(height: 24),
        CheckboxListTile(
          value: _consent,
          onChanged: (v) => setState(() => _consent = v ?? false),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(context.t('apply.consent', {'lender': widget.offer['lender']})),
          subtitle: Text(context.t('apply.consent_sub')),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _consent && !_busy ? _submit : null,
          child: _busy
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(context.t('apply.submit')),
        ),
      ]),
    );
  }
}
