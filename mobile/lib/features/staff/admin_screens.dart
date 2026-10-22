import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/theme.dart';
import '../../shared/widgets/brand.dart';
import '../../shared/widgets/common.dart';

final settingsProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final api = ref.watch(apiProvider);
  final res = await Future.wait([api.get('/org/settings'), api.get('/org/offer-rules')]);
  return {'settings': res[0], 'rules': res[1]};
});

final teamProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final res = await ref.watch(apiProvider).get('/org/team') as List;
  return res.map((e) => Map<String, dynamic>.from(e as Map)).toList();
});

final auditProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, int>((ref, limit) async {
  final res = await ref.watch(apiProvider).get('/org/audit', query: {'limit': '$limit'}) as List;
  return res.map((e) => Map<String, dynamic>.from(e as Map)).toList();
});

/// Decision settings (cost ratio, review capacity, SLA) and offer rules (rates, limits, ladder caps).
class RulesScreen extends ConsumerWidget {
  const RulesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(settingsProvider);
    return Scaffold(
      body: SafeArea(
        child: AsyncView<Map<String, dynamic>>(
          value: data,
          onRetry: () => ref.invalidate(settingsProvider),
          builder: (d) => _RulesForm(
            key: ValueKey(d.hashCode),
            settings: Map<String, dynamic>.from(d['settings'] as Map),
            rules: Map<String, dynamic>.from((d['rules'] as Map)['rules'] as Map),
            limits: Map<String, dynamic>.from((d['rules'] as Map)['limits'] as Map),
          ),
        ),
      ),
    );
  }
}

class _RulesForm extends ConsumerStatefulWidget {
  final Map<String, dynamic> settings;
  final Map<String, dynamic> rules;
  final Map<String, dynamic> limits;
  const _RulesForm({super.key, required this.settings, required this.rules, required this.limits});

  @override
  ConsumerState<_RulesForm> createState() => _RulesFormState();
}

class _RulesFormState extends ConsumerState<_RulesForm> {
  late double _ratio = (widget.settings['cost_ratio'] as num).toDouble();
  late bool _capOn = widget.settings['review_capacity'] != null;
  late double _cap = ((widget.settings['review_capacity'] as num?) ?? 0.3).toDouble();
  late double _sla = ((widget.settings['sla_hours'] as num?) ?? 48).toDouble();
  late double _base = (widget.rules['base_rate'] as num).toDouble();
  late double _step = (widget.rules['rate_step'] as num).toDouble();
  late final _minAmount = TextEditingController(text: '${(widget.rules['min_amount'] as num).round()}');
  late final _maxAmount = TextEditingController(text: '${(widget.rules['max_amount'] as num).round()}');
  late final _minIncome = TextEditingController(text: '${(widget.rules['min_income'] as num).round()}');
  late double _maxDti = (widget.rules['max_dti'] as num).toDouble();
  late double _share = (widget.rules['max_income_share'] as num).toDouble();
  late Set<int> _terms = (widget.rules['terms'] as List).map((e) => (e as num).toInt()).toSet();
  late List<double> _caps = (widget.rules['ladder_caps'] as List).map((e) => (e as num).toDouble()).toList();
  bool _busy = false;

  @override
  void dispose() {
    _minAmount.dispose();
    _maxAmount.dispose();
    _minIncome.dispose();
    super.dispose();
  }

  bool get _admin => ref.read(sessionProvider).isAdmin;

  Future<void> _saveSettings() async {
    setState(() => _busy = true);
    await runBusy(context, () async {
      await ref.read(apiProvider).put('/org/settings', {
        'cost_ratio': _ratio.round(),
        if (_capOn) 'review_capacity': double.parse(_cap.toStringAsFixed(2)) else 'clear_capacity': true,
        'sla_hours': _sla.round(),
      });
      if (mounted) showInfo(context, context.t('common.saved'));
      ref.invalidate(settingsProvider);
    });
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _saveRules() async {
    setState(() => _busy = true);
    await runBusy(context, () async {
      await ref.read(apiProvider).put('/org/offer-rules', {
        'base_rate': double.parse(_base.toStringAsFixed(1)),
        'rate_step': double.parse(_step.toStringAsFixed(1)),
        'min_amount': double.tryParse(_minAmount.text),
        'max_amount': double.tryParse(_maxAmount.text),
        'min_income': double.tryParse(_minIncome.text),
        'max_dti': double.parse(_maxDti.toStringAsFixed(2)),
        'max_income_share': double.parse(_share.toStringAsFixed(2)),
        'terms': (_terms.toList()..sort()),
        'ladder_caps': _caps.map((c) => double.parse(c.toStringAsFixed(2))).toList(),
      });
      if (mounted) showInfo(context, context.t('common.saved'));
      ref.invalidate(settingsProvider);
    });
    if (mounted) setState(() => _busy = false);
  }

  Widget _slider(String label, String value, double v, double min, double max, int div, ValueChanged<double> onChanged) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: Text(label, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600))),
        Text(value, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
      ]),
      Slider(value: v.clamp(min, max).toDouble(), min: min, max: max, divisions: div, onChanged: _admin ? onChanged : null),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = widget.settings;
    final allTerms = (widget.limits['terms'] as List).map((e) => (e as num).toInt()).toList();
    return PageList(width: 820, children: [
      PageHeader(title: context.t('rules.title'), subtitle: context.t('rules.subtitle')),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(context.t('rules.decision'), style: theme.textTheme.titleMedium),
            Text(context.t('rules.decision_help'), style: theme.textTheme.bodySmall),
            _slider(context.t('rules.cost_ratio'), context.t('rules.cost_ratio_value', {'n': context.digits(_ratio.round())}), _ratio, 1,
                (s['max_cost_ratio'] as num).toDouble(), (s['max_cost_ratio'] as num).toInt() - 1, (v) => setState(() => _ratio = v)),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(context.t('rules.capacity')),
              subtitle: Text(context.t('rules.capacity_help')),
              value: _capOn,
              onChanged: _admin ? (v) => setState(() => _capOn = v) : null,
            ),
            if (_capOn) _slider(context.t('rules.capacity_share'), context.pct(_cap, digits: 0), _cap, 0.05, 1, 19, (v) => setState(() => _cap = v)),
            _slider(context.t('rules.sla'), context.t('rules.hours', {'n': context.digits(_sla.round())}), _sla, 4, 168, 41,
                (v) => setState(() => _sla = v)),
            const SizedBox(height: 4),
            Text(context.t('rules.threshold_now', {'t': context.num0(s['recommendation_threshold'] as num?, digits: 3)}),
                style: theme.textTheme.bodySmall),
            if (_admin) ...[
              const SizedBox(height: 12),
              Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(onPressed: _busy ? null : _saveSettings, child: Text(context.t('common.save')))),
            ],
          ]),
        ),
      ),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(context.t('rules.offers'), style: theme.textTheme.titleMedium),
            Text(context.t('rules.offers_help'), style: theme.textTheme.bodySmall),
            _slider(context.t('rules.base_rate'), '${context.num0(_base, digits: 1)}%', _base, (widget.limits['rate_min'] as num).toDouble(),
                (widget.limits['rate_max'] as num).toDouble(), 46, (v) => setState(() => _base = v)),
            _slider(context.t('rules.rate_step'), '+${context.num0(_step, digits: 1)}%', _step, 0, 10, 20, (v) => setState(() => _step = v)),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: TextField(
                    controller: _minAmount,
                    enabled: _admin,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: context.t('rules.min_amount'))),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                    controller: _maxAmount,
                    enabled: _admin,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: context.t('rules.max_amount'))),
              ),
            ]),
            const SizedBox(height: 12),
            Text(context.t('rules.terms'), style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Wrap(spacing: 6, children: [
              for (final t in allTerms)
                FilterChip(
                  label: Text(context.t('common.months', {'n': context.digits(t)})),
                  selected: _terms.contains(t),
                  onSelected: !_admin
                      ? null
                      : (v) => setState(() {
                            if (v) {
                              _terms.add(t);
                            } else if (_terms.length > 1) {
                              _terms.remove(t);
                            }
                          }),
                ),
            ]),
            const SizedBox(height: 12),
            TextField(
                controller: _minIncome,
                enabled: _admin,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: context.t('rules.min_income'))),
            _slider(context.t('rules.max_dti'), context.num0(_maxDti, digits: 2), _maxDti, 0.1, 1, 18, (v) => setState(() => _maxDti = v)),
            _slider(context.t('rules.income_share'), context.pct(_share, digits: 0), _share, 0.1, 0.6, 10, (v) => setState(() => _share = v)),
            const SizedBox(height: 8),
            Text(context.t('rules.ladder'), style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            Text(context.t('rules.ladder_help'), style: theme.textTheme.bodySmall),
            for (var i = 0; i < 3; i++)
              _slider('L${i + 1} ${context.code('ladder', ['Starter', 'Builder', 'Trusted'][i])}', context.pct(_caps[i], digits: 0), _caps[i], 0.05,
                  0.95, 18, (v) => setState(() {
                    _caps = [..._caps];
                    _caps[i] = v;
                    for (var j = i + 1; j < 3; j++) {
                      if (_caps[j] < v) _caps[j] = v;
                    }
                    for (var j = 0; j < i; j++) {
                      if (_caps[j] > v) _caps[j] = v;
                    }
                  })),
            Text('L4 ${context.code('ladder', 'Prime')}: 100%', style: theme.textTheme.bodySmall),
            if (_admin) ...[
              const SizedBox(height: 12),
              Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(onPressed: _busy ? null : _saveRules, child: Text(context.t('rules.save_offers')))),
            ],
          ]),
        ),
      ),
    ]);
  }
}

class TeamScreen extends ConsumerWidget {
  const TeamScreen({super.key});

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final name = TextEditingController();
    final email = TextEditingController();
    final password = TextEditingController();
    var role = 'officer';
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, setD) => AlertDialog(
          title: Text(context.t('team.add')),
          content: SizedBox(
            width: 400,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: name, decoration: InputDecoration(labelText: context.t('field.name'))),
              const SizedBox(height: 8),
              TextField(controller: email, decoration: InputDecoration(labelText: context.t('field.email'))),
              const SizedBox(height: 8),
              TextField(
                  controller: password,
                  decoration: InputDecoration(labelText: context.t('team.temp_password'), helperText: context.t('register.password_help'))),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(value: 'officer', label: Text(context.code('role', 'officer'))),
                  ButtonSegment(value: 'admin', label: Text(context.code('role', 'admin'))),
                ],
                selected: {role},
                onSelectionChanged: (s) => setD(() => role = s.first),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: Text(context.t('common.cancel'))),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(context.t('team.add'))),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    await runBusy(context, () async {
      await ref.read(apiProvider).post('/org/team', {'name': name.text, 'email': email.text, 'password': password.text, 'role': role});
      ref.invalidate(teamProvider);
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final team = ref.watch(teamProvider);
    final me = ref.watch(sessionProvider);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _add(context, ref), icon: const Icon(Icons.person_add_alt), label: Text(context.t('team.add'))),
      body: SafeArea(
        child: AsyncView<List<Map<String, dynamic>>>(
          value: team,
          onRetry: () => ref.invalidate(teamProvider),
          builder: (list) => PageList(children: [
            PageHeader(title: context.t('team.title'), subtitle: me.orgName),
            for (final m in list)
              Card(
                child: ListTile(
                  leading: CircleAvatar(child: Text((m['name'] as String).isEmpty ? '?' : (m['name'] as String)[0])),
                  title: Text(m['name'] as String),
                  subtitle: Text('${m['email']} · ${context.code('role', m['role'] as String?)}${m['totp_enabled'] == 1 ? ' · 2FA' : ''}'),
                  trailing: Switch(
                    value: m['active'] == 1 || m['active'] == true,
                    onChanged: m['id'] == me.userId
                        ? null
                        : (v) => runBusy(context, () async {
                              await ref.read(apiProvider).patch('/org/team/${m['id']}', {'active': v});
                              ref.invalidate(teamProvider);
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

class AuditScreen extends ConsumerStatefulWidget {
  const AuditScreen({super.key});

  @override
  ConsumerState<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends ConsumerState<AuditScreen> {
  int _limit = 50;

  @override
  Widget build(BuildContext context) {
    final log = ref.watch(auditProvider(_limit));
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: AsyncView<List<Map<String, dynamic>>>(
          value: log,
          onRetry: () => ref.invalidate(auditProvider(_limit)),
          builder: (list) => PageList(
            onRefresh: () async => ref.invalidate(auditProvider(_limit)),
            children: [
              PageHeader(title: context.t('audit.title'), subtitle: context.t('audit.subtitle')),
              Card(
                child: Column(children: [
                  for (final e in list)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.history, color: Brand.muted),
                      title: Text(context.code('action', e['action'] as String?, fallback: e['action'] as String?)),
                      subtitle: Text('${e['user_name'] ?? context.t('audit.system')} · ${e['target'] ?? ''}'),
                      trailing: Text(context.dateTime(e['created_at'] as String?), style: theme.textTheme.bodySmall),
                    ),
                ]),
              ),
              if (list.length >= _limit)
                OutlinedButton(onPressed: () => setState(() => _limit += 50), child: Text(context.t('common.load_more'))),
            ],
          ),
        ),
      ),
    );
  }
}
