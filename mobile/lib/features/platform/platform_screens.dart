import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/format.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/theme.dart';
import '../../shared/widgets/brand.dart';
import '../../shared/widgets/common.dart';
import '../borrower/borrower_shell.dart';

final platformStatsProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  return await ref.watch(apiProvider).get('/admin/stats') as Map<String, dynamic>;
});

final orgsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final res = await ref.watch(apiProvider).get('/admin/orgs') as List;
  return res.map((e) => Map<String, dynamic>.from(e as Map)).toList();
});

final modelsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final res = await ref.watch(apiProvider).get('/admin/models') as List;
  return res.map((e) => Map<String, dynamic>.from(e as Map)).toList();
});

final flagsJobsProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final api = ref.watch(apiProvider);
  final res = await Future.wait([api.get('/admin/flags'), api.get('/admin/jobs')]);
  return {'flags': res[0], 'jobs': res[1]};
});

class PlatformShell extends ConsumerWidget {
  final Widget child;
  final String location;
  const PlatformShell({super.key, required this.child, required this.location});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = [
      NavItem('/platform', context.t('nav.overview'), Icons.space_dashboard_outlined, Icons.space_dashboard),
      NavItem('/platform/lenders', context.t('nav.lenders'), Icons.account_balance_outlined, Icons.account_balance),
      NavItem('/platform/models', context.t('nav.models'), Icons.model_training_outlined, Icons.model_training),
      NavItem('/platform/settings', context.t('nav.settings'), Icons.toggle_on_outlined, Icons.toggle_on),
      NavItem('/platform/account', context.t('nav.account'), Icons.person_outline, Icons.person),
    ];
    return AdaptiveShell(items: items, location: location, child: child);
  }
}

class PlatformOverviewScreen extends ConsumerWidget {
  const PlatformOverviewScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(platformStatsProvider);
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: AsyncView<Map<String, dynamic>>(
          value: data,
          onRetry: () => ref.invalidate(platformStatsProvider),
          builder: (s) {
            final funnel = Map<String, dynamic>.from(s['funnel_7d'] as Map);
            final model = Map<String, dynamic>.from(s['model'] as Map);
            final started = (funnel['started'] as num).toInt();
            return PageList(
              width: 1100,
              onRefresh: () async => ref.invalidate(platformStatsProvider),
              children: [
                PageHeader(title: context.t('platform.title'), subtitle: context.t('platform.subtitle')),
                Wrap(spacing: 12, runSpacing: 12, children: [
                  StatCard(label: context.t('platform.lenders'), value: context.digits(s['active_orgs']), icon: Icons.account_balance_outlined,
                      caption: context.t('platform.of_total', {'n': context.digits(s['orgs'])})),
                  StatCard(label: context.t('platform.borrowers'), value: context.digits(s['borrowers']), icon: Icons.people_outline, color: Brand.info),
                  StatCard(label: context.t('platform.applications'), value: context.digits(s['applications']), icon: Icons.description_outlined),
                  StatCard(label: context.t('platform.loans'), value: context.digits(s['loans_active']), icon: Icons.account_balance_wallet_outlined, color: Brand.success),
                  StatCard(
                      label: context.t('platform.outbox'),
                      value: context.digits(s['outbox_pending']),
                      icon: Icons.outbox_outlined,
                      color: (s['outbox_pending'] as num) > 20 ? Brand.warning : Brand.muted),
                ]),
                SectionTitle(context.t('platform.funnel')),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      for (final k in ['started', 'quick_check', 'full_profile', 'submitted'])
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          child: Row(children: [
                            SizedBox(width: 130, child: Text(context.t('funnel.$k'), style: theme.textTheme.bodySmall)),
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: started == 0 ? 0.0 : (funnel[k] as num) / started,
                                  minHeight: 12,
                                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                                ),
                              ),
                            ),
                            SizedBox(width: 50, child: Text(context.digits(funnel[k]), textAlign: TextAlign.right)),
                          ]),
                        ),
                      const Divider(height: 24),
                      KeyValue(context.t('platform.drop_off'), context.pct(s['drop_off_7d'] as num?),
                          strong: true),
                      KeyValue(context.t('platform.minutes'),
                          s['median_minutes_to_submit_7d'] == null ? '-' : context.num0(s['median_minutes_to_submit_7d'] as num, digits: 1)),
                      Text(context.t('platform.targets'), style: theme.textTheme.bodySmall),
                    ]),
                  ),
                ),
                SectionTitle(context.t('platform.model')),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.model_training_outlined),
                    title: Text(context.t('platform.active_model', {'v': model['active']})),
                    subtitle: Text(model['shadow'] == null
                        ? context.t('platform.no_shadow')
                        : context.t('platform.shadow_model', {'v': model['shadow']})),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class OrgsScreen extends ConsumerWidget {
  const OrgsScreen({super.key});

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final name = TextEditingController();
    final adminName = TextEditingController();
    final adminEmail = TextEditingController();
    final password = TextEditingController();
    var plan = 'free';
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, setD) => AlertDialog(
          title: Text(context.t('orgs.new')),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(controller: name, decoration: InputDecoration(labelText: context.t('orgs.name'))),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  segments: [for (final p in ['free', 'pro', 'enterprise']) ButtonSegment(value: p, label: Text(context.code('plan', p)))],
                  selected: {plan},
                  onSelectionChanged: (s) => setD(() => plan = s.first),
                ),
                const SizedBox(height: 8),
                TextField(controller: adminName, decoration: InputDecoration(labelText: context.t('orgs.admin_name'))),
                const SizedBox(height: 8),
                TextField(controller: adminEmail, decoration: InputDecoration(labelText: context.t('orgs.admin_email'))),
                const SizedBox(height: 8),
                TextField(controller: password, decoration: InputDecoration(labelText: context.t('team.temp_password'))),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: Text(context.t('common.cancel'))),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(context.t('orgs.create'))),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    await runBusy(context, () async {
      await ref.read(apiProvider).post('/admin/orgs', {
        'name': name.text,
        'plan': plan,
        'admin_name': adminName.text,
        'admin_email': adminEmail.text,
        'admin_password': password.text,
      });
      ref.invalidate(orgsProvider);
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orgs = ref.watch(orgsProvider);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _create(context, ref), icon: const Icon(Icons.add_business_outlined), label: Text(context.t('orgs.new'))),
      body: SafeArea(
        child: AsyncView<List<Map<String, dynamic>>>(
          value: orgs,
          onRetry: () => ref.invalidate(orgsProvider),
          builder: (list) => PageList(width: 900, children: [
            PageHeader(title: context.t('orgs.title'), subtitle: context.t('orgs.subtitle')),
            for (final o in list)
              Card(
                child: ListTile(
                  leading: IconTile(icon: Icons.account_balance_outlined, color: Theme.of(context).colorScheme.primary),
                  title: Text(o['name'] as String),
                  subtitle: Text(context.t('orgs.line', {
                    'plan': context.code('plan', o['plan'] as String?),
                    'staff': context.digits(o['staff']),
                    'apps': context.digits(o['applications']),
                    'loans': context.digits(o['active_loans']),
                  })),
                  trailing: Switch(
                    value: o['active'] == 1 || o['active'] == true,
                    onChanged: (v) => runBusy(context, () async {
                      await ref.read(apiProvider).patch('/admin/orgs/${o['id']}', {'active': v});
                      ref.invalidate(orgsProvider);
                    }),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

/// Model registry: candidate -> shadow -> active, with the shadow comparison report.
class ModelsScreen extends ConsumerWidget {
  const ModelsScreen({super.key});

  static const _next = {
    'candidate': ['shadow', 'retired'],
    'shadow': ['active', 'candidate'],
    'retired': ['candidate'],
    'active': <String>[],
  };

  Future<void> _promote(BuildContext context, WidgetRef ref, Map<String, dynamic> m, String to) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(context.t('models.promote_q', {'v': m['version'], 'to': context.code('status', to)})),
        content: Text(context.t('models.promote_$to')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(context.t('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(context.t('common.confirm'))),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await runBusy(context, () async {
      await ref.read(apiProvider).post('/admin/models/${m['id']}/promote', {'to': to});
      ref.invalidate(modelsProvider);
      ref.invalidate(platformStatsProvider);
    });
  }

  Future<void> _report(BuildContext context, WidgetRef ref, Map<String, dynamic> m) async {
    final rep = await runBusy(context, () async => await ref.read(apiProvider).get('/admin/models/${m['id']}/shadow-report') as Map<String, dynamic>);
    if (rep == null || !context.mounted) return;
    Widget part(String title, Map? p) {
      if (p == null) return const SizedBox.shrink();
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SectionTitle(title),
        KeyValue(context.t('models.n'), context.digits(p['n'] ?? 0)),
        KeyValue(context.t('models.agreement'), context.pct(p['agreement'] as num?)),
        KeyValue(context.t('models.tighten'), context.digits(p['would_tighten'] ?? 0)),
        KeyValue(context.t('models.loosen'), context.digits(p['would_loosen'] ?? 0)),
        KeyValue(context.t('models.delta'), context.pct(p['mean_abs_probability_change'] as num?, digits: 2)),
      ]);
    }

    await showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(context.t('models.report', {'v': rep['version']})),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              part(context.t('models.live'), rep['live'] as Map?),
              part(context.t('models.offline'), rep['offline'] as Map?),
            ]),
          ),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(d), child: Text(context.t('common.close')))],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final models = ref.watch(modelsProvider);
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: AsyncView<List<Map<String, dynamic>>>(
          value: models,
          onRetry: () => ref.invalidate(modelsProvider),
          builder: (list) => PageList(width: 900, children: [
            PageHeader(title: context.t('models.title'), subtitle: context.t('models.subtitle')),
            for (final m in list)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text(m['version'] as String, style: theme.textTheme.titleMedium)),
                      Pill(label: context.code('status', m['status'] as String?), color: statusColors[m['status']] ?? Brand.muted, dense: true),
                    ]),
                    if (m['notes'] != null) Text(m['notes'] as String, style: theme.textTheme.bodySmall),
                    const SizedBox(height: 8),
                    Wrap(spacing: 16, runSpacing: 6, children: [
                      Text('AUC ${context.num0((m['metrics'] as Map)['roc_auc'] as num?, digits: 3)}'),
                      Text('${context.t('models.savings')} ${context.pct((m['metrics'] as Map)['savings_pct'] as num?)}'),
                      for (final e in Map<String, dynamic>.from((m['metrics'] as Map)['worst_disparate_impact'] as Map? ?? const {}).entries)
                        Text('${context.t('models.di')} ${e.key}: ${context.num0(e.value as num?, digits: 2)}',
                            style: TextStyle(color: (e.value as num) < 0.8 ? Brand.danger : null)),
                    ]),
                    const SizedBox(height: 4),
                    Text(context.t('models.scored', {'n': context.digits(m['scored']), 'shadow': context.digits(m['shadow_n'])}),
                        style: theme.textTheme.bodySmall),
                    const SizedBox(height: 10),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final to in _next[m['status']] ?? const <String>[])
                        OutlinedButton(
                            onPressed: () => _promote(context, ref, m, to),
                            child: Text(context.t('models.to', {'to': context.code('status', to)}))),
                      if (m['status'] != 'active')
                        TextButton.icon(
                            onPressed: () => _report(context, ref, m), icon: const Icon(Icons.compare_arrows), label: Text(context.t('models.compare'))),
                    ]),
                  ]),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

class PlatformSettingsScreen extends ConsumerWidget {
  const PlatformSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(flagsJobsProvider);
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: AsyncView<Map<String, dynamic>>(
          value: data,
          onRetry: () => ref.invalidate(flagsJobsProvider),
          builder: (d) {
            final flags = (d['flags'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
            final jobs = (d['jobs'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
            return PageList(width: 900, children: [
              PageHeader(title: context.t('psettings.title'), subtitle: context.t('psettings.subtitle')),
              SectionTitle(context.t('psettings.flags')),
              Card(
                child: Column(children: [
                  for (final f in flags)
                    SwitchListTile(
                      title: Text(context.code('flag', f['key'] as String?, fallback: f['key'] as String?)),
                      subtitle: Text(context.code('flag_help', f['key'] as String?, fallback: '')),
                      value: f['enabled'] == true,
                      onChanged: (v) => runBusy(context, () async {
                        await ref.read(apiProvider).put('/admin/flags/${f['key']}', {'enabled': v});
                        ref.invalidate(flagsJobsProvider);
                      }),
                    ),
                ]),
              ),
              SectionTitle(context.t('psettings.jobs')),
              Card(
                child: Column(children: [
                  for (final j in jobs)
                    ListTile(
                      title: Text(context.code('job', j['name'] as String?, fallback: j['name'] as String?)),
                      subtitle: Text(j['last_run_at'] == null
                          ? context.t('psettings.never')
                          : context.t('psettings.last_run', {'when': context.ago(j['last_run_at'] as String?)})),
                      trailing: TextButton(
                        onPressed: () => runBusy(context, () async {
                          await ref.read(apiProvider).post('/admin/jobs/${j['name']}/run');
                          ref.invalidate(flagsJobsProvider);
                          if (context.mounted) showInfo(context, context.t('psettings.ran'));
                        }),
                        child: Text(context.t('psettings.run')),
                      ),
                    ),
                ]),
              ),
              Text(context.t('psettings.jobs_help'), style: theme.textTheme.bodySmall),
            ]);
          },
        ),
      ),
    );
  }
}
