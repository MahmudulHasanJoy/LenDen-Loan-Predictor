import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/auth/session.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/theme.dart';
import '../../shared/widgets/common.dart';
import '../../shared/widgets/explain.dart';
import '../../shared/widgets/odds.dart';
import '../../shared/widgets/progress.dart';
import 'queue_screen.dart';

final staffApplicationProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, int>((ref, id) async {
  return await ref.watch(apiProvider).get('/org/applications/$id') as Map<String, dynamic>;
});

const docKinds = ['bank_statements_3m', 'salary_slip', 'national_id', 'trade_license', 'utility_bill', 'other'];

/// Everything an officer needs to decide: inputs, odds, reasons, the counterfactual,
/// similar past decisions, documents and the timeline, plus the decision panel.
class StaffApplicationScreen extends ConsumerStatefulWidget {
  final int id;
  const StaffApplicationScreen({super.key, required this.id});

  @override
  ConsumerState<StaffApplicationScreen> createState() => _StaffApplicationScreenState();
}

class _StaffApplicationScreenState extends ConsumerState<StaffApplicationScreen> {
  bool _busy = false;

  void _reload() {
    ref.invalidate(staffApplicationProvider(widget.id));
    ref.invalidate(queueProvider);
  }

  Future<void> _post(String path, [Map<String, dynamic>? body, String? done]) async {
    setState(() => _busy = true);
    await runBusy(context, () async {
      await ref.read(apiProvider).post(path, body ?? const {});
      if (done != null && mounted) showInfo(context, done);
      _reload();
    });
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _approve(Map<String, dynamic> a) async {
    final terms = Map<String, dynamic>.from(a['terms'] as Map? ?? const {});
    final amount = TextEditingController(text: '${(terms['amount'] ?? a['loan_amount'] as num).round()}');
    final term = TextEditingController(text: '${terms['term'] ?? (a['inputs'] as Map)['LoanTerm']}');
    final rate = TextEditingController(text: '${terms['rate'] ?? (a['inputs'] as Map)['InterestRate']}');
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(context.t('decide.approve_title')),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: amount, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('field.LoanAmount'))),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: TextField(controller: term, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('decide.term_months')))),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: rate, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: context.t('decide.rate')))),
            ]),
            const SizedBox(height: 8),
            TextField(controller: note, maxLines: 2, decoration: InputDecoration(labelText: context.t('decide.note_optional'))),
            const SizedBox(height: 8),
            Text(context.t('decide.approve_help'), style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(context.t('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(context.t('decide.approve'))),
        ],
      ),
    );
    if (ok != true) return;
    await _post('/org/applications/${widget.id}/decision', {
      'decision': 'approved',
      'note': note.text,
      'terms': {
        'amount': double.tryParse(amount.text),
        'term': int.tryParse(term.text),
        'rate': double.tryParse(rate.text),
      },
    }, mounted ? context.t('decide.approved') : null);
  }

  Future<void> _reject(Map<String, dynamic> a) async {
    final catalog = Map<String, dynamic>.from(a['reason_catalog'] as Map? ?? const {});
    final suggested = (a['reasons'] as List? ?? const [])
        .map((r) => Map<String, dynamic>.from(r as Map))
        .where((r) => (r['impact'] as num) > 0 && r['code'] != null && catalog.containsKey(r['code']))
        .map((r) => r['code'] as String)
        .take(2)
        .toSet();
    final selected = <String>{...suggested};
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, setD) => AlertDialog(
          title: Text(context.t('decide.reject_title')),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(context.t('decide.reject_help')),
                const SizedBox(height: 10),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final code in catalog.keys)
                    FilterChip(
                      label: Text(context.code('reason', code, fallback: catalog[code] as String?)),
                      selected: selected.contains(code),
                      onSelected: (v) => setD(() => v ? selected.add(code) : selected.remove(code)),
                    ),
                ]),
                const SizedBox(height: 10),
                TextField(controller: note, maxLines: 2, decoration: InputDecoration(labelText: context.t('decide.note_borrower'))),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: Text(context.t('common.cancel'))),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Brand.danger),
              onPressed: selected.isEmpty && note.text.trim().isEmpty ? null : () => Navigator.pop(d, true),
              child: Text(context.t('decide.reject')),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await _post('/org/applications/${widget.id}/decision',
        {'decision': 'rejected', 'note': note.text, 'reason_codes': selected.toList()}, mounted ? context.t('decide.rejected') : null);
  }

  Future<void> _requestDocs() async {
    final selected = <String>{'bank_statements_3m'};
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, setD) => AlertDialog(
          title: Text(context.t('decide.docs_title')),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final k in docKinds)
                CheckboxListTile(
                  dense: true,
                  value: selected.contains(k),
                  title: Text(context.code('doc', k)),
                  onChanged: (v) => setD(() => (v ?? false) ? selected.add(k) : selected.remove(k)),
                ),
              TextField(controller: note, decoration: InputDecoration(labelText: context.t('decide.note_borrower'))),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: Text(context.t('common.cancel'))),
            FilledButton(onPressed: selected.isEmpty ? null : () => Navigator.pop(d, true), child: Text(context.t('decide.send_request'))),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await _post('/org/applications/${widget.id}/document-requests',
        {'documents': selected.toList(), 'note': note.text}, mounted ? context.t('decide.docs_sent') : null);
  }

  Future<void> _openDoc(int id) async {
    await runBusy(context, () async {
      final api = ref.read(apiProvider);
      final link = await api.get('/documents/$id/link') as Map<String, dynamic>;
      await launchUrl(Uri.parse(api.url(link['url'] as String)), mode: LaunchMode.externalApplication);
    });
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(staffApplicationProvider(widget.id));
    final me = ref.watch(sessionProvider);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => context.go('/staff')),
        title: Text(context.t('staff_app.title', {'id': context.digits(widget.id)})),
      ),
      body: AsyncView<Map<String, dynamic>>(
        value: data,
        onRetry: _reload,
        builder: (a) {
          final status = a['status'] as String;
          final open = ['submitted', 'in_review', 'needs_docs'].contains(status);
          final assignedToMe = a['assigned_to'] == me.userId;
          final canDecide = open && (a['assigned_to'] == null || assignedToMe || me.isAdmin);
          final borrower = Map<String, dynamic>.from(a['borrower'] as Map);
          final inputs = Map<String, dynamic>.from(a['inputs'] as Map);
          final reasons = (a['reasons'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
          final similar = (a['similar'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
          final docs = (a['documents'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
          final requests = (a['document_requests'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
          final shadow = a['shadow'] == null ? null : Map<String, dynamic>.from(a['shadow'] as Map);
          final codes = (a['reason_codes'] as List? ?? const []).map((e) => e.toString()).toList();

          final summary = Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(borrower['name'] as String, style: theme.textTheme.titleLarge),
                      Text('${borrower['email']}${borrower['phone_verified'] == true ? ' · ${context.t('account.verified')}' : ''}',
                          style: theme.textTheme.bodySmall),
                    ]),
                  ),
                  StatusChip(status: status),
                ]),
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  OddsChip(odds: a['odds'] as String?),
                  LightBadge(light: a['light'] as String?),
                  Pill(
                      label: a['recommendation'] == 'APPROVE' ? context.t('queue.recommend_approve') : context.t('queue.recommend_review'),
                      color: a['recommendation'] == 'APPROVE' ? Brand.success : Brand.warning),
                  Pill(label: context.t('staff_app.level', {'n': context.digits(a['ladder_level'])}), color: Brand.info, icon: Icons.stairs_outlined),
                ]),
                const Divider(height: 24),
                KeyValue(context.t('field.LoanAmount'), context.money(a['loan_amount'] as num?), strong: true),
                KeyValue(context.t('staff_app.default_prob'), context.pct(a['default_probability'] as num?)),
                KeyValue(context.t('staff_app.threshold'), context.num0(a['threshold'] as num?, digits: 3)),
                KeyValue(context.t('staff_app.score'), context.num0(a['risk_score'] as num?, digits: 3)),
                KeyValue(context.t('staff_app.model'), a['model_version'] as String? ?? '-'),
                if (a['sla_due_at'] != null && open) KeyValue(context.t('staff_app.sla'), context.dateTime(a['sla_due_at'] as String?)),
                KeyValue(context.t('staff_app.assigned'), a['assigned_name'] as String? ?? context.t('queue.unassigned')),
                if (shadow != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(children: [
                      const Icon(Icons.science_outlined, size: 18, color: Color(0xFF7C3AED)),
                      const SizedBox(width: 6),
                      Expanded(child: Text(context.t('staff_app.shadow', {'version': shadow['version']}), style: theme.textTheme.bodySmall)),
                      OddsChip(odds: shadow['odds'] as String?, dense: true),
                    ]),
                  ),
              ]),
            ),
          );

          final actions = Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(context.t('decide.title'), style: theme.textTheme.titleMedium),
                const SizedBox(height: 10),
                if (!open) ...[
                  Text(context.t('decide.closed', {
                    'who': a['decided_by_name'] ?? '-',
                    'when': context.dateTime(a['decided_at'] as String?),
                  })),
                  if (codes.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: ReasonList(codes: codes)),
                  if ((a['decision_note'] as String?)?.isNotEmpty ?? false)
                    Padding(padding: const EdgeInsets.only(top: 8), child: Text('"${a['decision_note']}"')),
                  if (a['loan'] != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(context.t('decide.loan', {
                        'id': context.digits((a['loan'] as Map)['id']),
                        'status': context.code('status', (a['loan'] as Map)['status'] as String?)
                      })),
                    ),
                ] else ...[
                  if (a['assigned_to'] == null)
                    FilledButton.tonalIcon(
                      onPressed: _busy ? null : () => _post('/org/applications/${widget.id}/claim', null, context.t('decide.claimed')),
                      icon: const Icon(Icons.pan_tool_alt_outlined),
                      label: Text(context.t('decide.claim')),
                    )
                  else if (assignedToMe)
                    TextButton(
                        onPressed: _busy ? null : () => _post('/org/applications/${widget.id}/release'),
                        child: Text(context.t('decide.release'))),
                  if (!canDecide)
                    Text(context.t('decide.someone_else', {'who': a['assigned_name']}), style: theme.textTheme.bodySmall),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: _busy || !canDecide ? null : () => _approve(a),
                    icon: const Icon(Icons.check),
                    label: Text(context.t('decide.approve')),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _busy || !canDecide ? null : _requestDocs,
                    icon: const Icon(Icons.upload_file),
                    label: Text(context.t('decide.request_docs')),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(foregroundColor: Brand.danger),
                    onPressed: _busy || !canDecide ? null : () => _reject(a),
                    icon: const Icon(Icons.close),
                    label: Text(context.t('decide.reject')),
                  ),
                ],
              ]),
            ),
          );

          final explanation = Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(context.t('staff_app.drivers'), style: theme.textTheme.titleMedium),
                Text(context.t('staff_app.drivers_help'), style: theme.textTheme.bodySmall),
                const SizedBox(height: 10),
                for (final r in reasons)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(children: [
                      Icon((r['impact'] as num) > 0 ? Icons.arrow_upward : Icons.arrow_downward,
                          size: 18, color: (r['impact'] as num) > 0 ? Brand.danger : Brand.success),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                            '${context.field(r['feature'] as String)}: ${context.value(r['feature'] as String, r['value'])} (${context.t('staff_app.typical')} ${context.value(r['feature'] as String, r['typical'])})'),
                      ),
                      Text('${(r['impact'] as num) > 0 ? '+' : ''}${context.num0((r['impact'] as num) * 100, digits: 1)}',
                          style: theme.textTheme.titleSmall),
                    ]),
                  ),
              ]),
            ),
          );

          final inputsCard = Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(context.t('staff_app.inputs'), style: theme.textTheme.titleMedium),
                const SizedBox(height: 6),
                for (final e in inputs.entries)
                  KeyValue(context.field(e.key),
                      e.value is String ? context.code('option.${e.key}', e.value as String, fallback: e.value as String) : context.value(e.key, e.value)),
              ]),
            ),
          );

          final left = [
            summary,
            explanation,
            NextStepCard(step: a['next_step'] == null ? null : Map<String, dynamic>.from(a['next_step'] as Map)),
            inputsCard,
          ];
          final right = [
            actions,
            if (requests.isNotEmpty || docs.isNotEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(context.t('docs.title'), style: theme.textTheme.titleMedium),
                    for (final r in requests.where((r) => r['status'] == 'open'))
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(context.t('staff_app.waiting_docs', {
                          'n': context.digits((r['items'] as List).where((i) => (i as Map)['uploaded'] != true).length),
                          'date': context.date(r['due_at'] as String?),
                        })),
                      ),
                    for (final d in docs)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.description_outlined),
                        title: Text(context.code('doc', d['kind'] as String?)),
                        subtitle: Text('${d['filename']} · ${context.date(d['uploaded_at'] as String?)}'),
                        trailing: const Icon(Icons.open_in_new),
                        onTap: () => _openDoc(d['id'] as int),
                      ),
                  ]),
                ),
              ),
            if (similar.isNotEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(context.t('staff_app.similar'), style: theme.textTheme.titleMedium),
                    Text(context.t('staff_app.similar_help'), style: theme.textTheme.bodySmall),
                    for (final s in similar)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text('#${context.digits(s['id'])} · ${context.money(s['loan_amount'] as num?)}'),
                        subtitle: Text('${context.t('staff_app.score')} ${context.num0(s['risk_score'] as num?, digits: 3)}'),
                        trailing: StatusChip(status: s['status'] as String?, dense: true),
                        onTap: () => context.go('/staff/applications/${s['id']}'),
                      ),
                  ]),
                ),
              ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(context.t('apps.timeline'), style: theme.textTheme.titleMedium),
                  const SizedBox(height: 10),
                  StatusTimeline(events: (a['timeline'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList()),
                ]),
              ),
            ),
          ];

          return LayoutBuilder(builder: (context, c) {
            if (c.maxWidth >= 1000) {
              return SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: MaxWidth(
                  width: 1200,
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(flex: 3, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: left)),
                    const SizedBox(width: 16),
                    Expanded(flex: 2, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: right)),
                  ]),
                ),
              );
            }
            return PageList(onRefresh: () async => _reload(), children: [summary, actions, ...left.skip(1), ...right.skip(1)]);
          });
        },
      ),
    );
  }
}
