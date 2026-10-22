import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/auth/session.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/theme.dart';
import '../../shared/widgets/brand.dart';
import '../../shared/widgets/common.dart';
import '../../shared/widgets/explain.dart';
import '../../shared/widgets/odds.dart';
import '../../shared/widgets/progress.dart';

final myApplicationsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final res = await ref.watch(apiProvider).get('/applications/mine') as List;
  return res.map((e) => Map<String, dynamic>.from(e as Map)).toList();
});

final myApplicationProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, int>((ref, id) async {
  return await ref.watch(apiProvider).get('/applications/$id') as Map<String, dynamic>;
});

class MyApplicationsScreen extends ConsumerWidget {
  const MyApplicationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final apps = ref.watch(myApplicationsProvider);
    return Scaffold(
      body: SafeArea(
        child: AsyncView<List<Map<String, dynamic>>>(
          value: apps,
          onRetry: () => ref.invalidate(myApplicationsProvider),
          builder: (list) => PageList(
            onRefresh: () async => ref.invalidate(myApplicationsProvider),
            children: [
              PageHeader(title: context.t('apps.title'), subtitle: context.t('apps.subtitle')),
              if (list.isEmpty)
                EmptyState(
                  icon: Icons.description_outlined,
                  title: context.t('apps.empty'),
                  message: context.t('apps.empty_sub'),
                  action: FilledButton(onPressed: () => context.go('/check'), child: Text(context.t('welcome.cta'))),
                ),
              for (final a in list)
                Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    title: Text(a['lender'] as String),
                    subtitle: Text(
                        '${context.money(a['loan_amount'] as num?)} · ${context.code('option.LoanPurpose', a['loan_purpose'] as String?)} · ${context.date(a['created_at'] as String?)}'),
                    trailing: StatusChip(status: a['status'] as String?, dense: true),
                    onTap: () => context.go('/applications/${a['id']}'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Status timeline, documents, decision and what would help next time.
class ApplicationDetailScreen extends ConsumerStatefulWidget {
  final int id;
  const ApplicationDetailScreen({super.key, required this.id});

  @override
  ConsumerState<ApplicationDetailScreen> createState() => _ApplicationDetailScreenState();
}

class _ApplicationDetailScreenState extends ConsumerState<ApplicationDetailScreen> {
  bool _busy = false;

  void _refresh() {
    ref.invalidate(myApplicationProvider(widget.id));
    ref.invalidate(myApplicationsProvider);
  }

  Future<void> _upload(String kind) async {
    final picked = await FilePicker.platform
        .pickFiles(type: FileType.custom, allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png'], withData: true);
    if (picked == null || picked.files.isEmpty) return;
    final file = picked.files.single;
    final bytes = file.bytes;
    if (bytes == null) return;
    final ext = (file.extension ?? '').toLowerCase();
    final type = ext == 'pdf' ? 'application/pdf' : (ext == 'png' ? 'image/png' : 'image/jpeg');
    if (!mounted) return;
    setState(() => _busy = true);
    await runBusy(context, () async {
      await ref.read(apiProvider).upload('/applications/${widget.id}/documents',
          fields: {'kind': kind}, bytes: bytes, filename: file.name, contentType: type);
      if (mounted) showInfo(context, context.t('docs.uploaded'));
      _refresh();
    });
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _open(int docId) async {
    await runBusy(context, () async {
      final api = ref.read(apiProvider);
      final link = await api.get('/documents/$docId/link') as Map<String, dynamic>;
      await launchUrl(Uri.parse(api.url(link['url'] as String)), mode: LaunchMode.externalApplication);
    });
  }

  Future<void> _withdraw() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(context.t('apps.withdraw_q')),
        content: Text(context.t('apps.withdraw_body')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(context.t('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(context.t('apps.withdraw'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await runBusy(context, () async {
      await ref.read(apiProvider).post('/applications/${widget.id}/withdraw');
      _refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(myApplicationProvider(widget.id));
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => context.go('/applications')),
        title: Text(context.t('apps.detail')),
      ),
      body: AsyncView<Map<String, dynamic>>(
        value: app,
        onRetry: _refresh,
        builder: (a) {
          final status = a['status'] as String;
          final open = ['submitted', 'in_review', 'needs_docs'].contains(status);
          final terms = a['terms'] == null ? null : Map<String, dynamic>.from(a['terms'] as Map);
          final requests = (a['document_requests'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
          final openReq = requests.where((r) => r['status'] == 'open').toList();
          final docs = (a['documents'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
          final codes = (a['reason_codes'] as List? ?? const []).map((e) => e.toString()).toList();
          return PageList(onRefresh: () async => _refresh(), children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text(a['lender'] as String, style: theme.textTheme.titleLarge)),
                    StatusChip(status: status),
                  ]),
                  const SizedBox(height: 8),
                  KeyValue(context.t('field.LoanAmount'), context.money((terms?['amount'] ?? a['loan_amount']) as num?), strong: true),
                  if (terms != null) ...[
                    KeyValue(context.t('offers.term'), context.t('common.months', {'n': context.digits(terms['term'])})),
                    KeyValue(context.t('offers.rate'), context.t('common.rate_pa', {'rate': context.num0(terms['rate'] as num?, digits: 1)})),
                    if (terms['emi'] != null) KeyValue(context.t('offers.emi'), context.money(terms['emi'] as num?)),
                  ],
                  if (a['odds'] != null && open)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(children: [
                        Text(context.t('apps.estimated_odds'), style: theme.textTheme.bodySmall),
                        const SizedBox(width: 8),
                        OddsChip(odds: a['odds'] as String?, dense: true),
                      ]),
                    ),
                ]),
              ),
            ),
            if (status == 'approved' && a['loan_id'] != null)
              Card(
                color: Brand.success.withValues(alpha: 0.08),
                child: ListTile(
                  leading: const Icon(Icons.celebration_outlined, color: Brand.success),
                  title: Text(context.t('apps.approved_title')),
                  subtitle: Text(context.t('apps.approved_sub')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.go('/loans/${a['loan_id']}'),
                ),
              ),
            if (status == 'rejected')
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(context.t('apps.rejected_title'), style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    ReasonList(codes: codes.where((c) => c != 'OTHER').toList()),
                    if ((a['decision_note'] as String?)?.isNotEmpty ?? false)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text('"${a['decision_note']}"', style: theme.textTheme.bodyMedium),
                      ),
                    const SizedBox(height: 8),
                    Text(context.t('apps.rejected_rights'), style: theme.textTheme.bodySmall),
                  ]),
                ),
              ),
            NextStepCard(step: a['next_step'] == null ? null : Map<String, dynamic>.from(a['next_step'] as Map)),
            if (status == 'rejected')
              OutlinedButton.icon(
                  onPressed: () => context.go('/check'), icon: const Icon(Icons.refresh), label: Text(context.t('apps.check_again'))),
            for (final r in openReq)
              Card(
                color: const Color(0xFF7C3AED).withValues(alpha: 0.06),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      const Icon(Icons.upload_file, color: Color(0xFF7C3AED)),
                      const SizedBox(width: 8),
                      Expanded(child: Text(context.t('docs.requested'), style: theme.textTheme.titleMedium)),
                    ]),
                    Text(context.t('docs.due', {'date': context.date(r['due_at'] as String?)}), style: theme.textTheme.bodySmall),
                    if ((r['note'] as String?)?.isNotEmpty ?? false)
                      Padding(padding: const EdgeInsets.only(top: 6), child: Text('"${r['note']}"')),
                    const SizedBox(height: 8),
                    for (final item in (r['items'] as List).map((e) => Map<String, dynamic>.from(e as Map)))
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(item['uploaded'] == true ? Icons.check_circle : Icons.radio_button_unchecked,
                            color: item['uploaded'] == true ? Brand.success : Brand.muted),
                        title: Text(context.code('doc', item['kind'] as String?, fallback: item['label'] as String?)),
                        trailing: item['uploaded'] == true
                            ? null
                            : FilledButton.tonal(
                                onPressed: _busy ? null : () => _upload(item['kind'] as String),
                                child: Text(context.t('docs.upload'))),
                      ),
                    Text(context.t('docs.types'), style: theme.textTheme.bodySmall),
                  ]),
                ),
              ),
            if (docs.isNotEmpty) ...[
              SectionTitle(context.t('docs.title')),
              Card(
                child: Column(children: [
                  for (final d in docs)
                    ListTile(
                      leading: Icon(d['content_type'] == 'application/pdf' ? Icons.picture_as_pdf_outlined : Icons.image_outlined),
                      title: Text(d['filename'] as String),
                      subtitle: Text('${context.code('doc', d['kind'] as String?)} · ${context.date(d['uploaded_at'] as String?)}'),
                      trailing: const Icon(Icons.open_in_new),
                      onTap: () => _open(d['id'] as int),
                    ),
                ]),
              ),
            ],
            SectionTitle(context.t('apps.timeline')),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: StatusTimeline(
                    events: (a['timeline'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList()),
              ),
            ),
            if (open)
              TextButton.icon(
                onPressed: _busy ? null : _withdraw,
                icon: const Icon(Icons.undo),
                label: Text(context.t('apps.withdraw')),
                style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
              ),
          ]);
        },
      ),
    );
  }
}
