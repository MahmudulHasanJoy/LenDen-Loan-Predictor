import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/session.dart';
import '../../widgets/account_menu.dart';
import '../../widgets/brand.dart';
import '../../widgets/common.dart';

/// Lender overview: volumes, approval rate, fairness monitor and input drift.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dashboard'), actions: const [AccountMenu()]),
      body: Loader<Map<String, dynamic>>(
        load: () async => await AppScope.read(context).api.get('/org/dashboard') as Map<String, dynamic>,
        builder: (context, d, reload) => RefreshIndicator(
          onRefresh: reload,
          child: MaxWidth(width: 1000, child: _Body(d: d)),
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  final Map<String, dynamic> d;

  const _Body({required this.d});

  @override
  Widget build(BuildContext context) {
    final totals = d['totals'] as Map<String, dynamic>;
    final lights = d['lights'] as Map<String, dynamic>;
    final settings = d['settings'] as Map<String, dynamic>;
    final hours = d['avg_hours_to_decision'];
    final session = AppScope.of(context);
    final first = session.name.split(' ').first;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        PageHeader(
          title: '${greeting()}, $first',
          subtitle: "Here's how ${session.orgName} is doing.",
        ),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            StatCard(label: 'Applications', value: '${totals['applications']}', icon: Icons.description_outlined),
            StatCard(label: 'Waiting for review', value: '${totals['pending']}', icon: Icons.inbox_outlined,
                color: const Color(0xFF2563EB)),
            StatCard(label: 'Approval rate', value: pct(d['approval_rate'] as num?, 0),
                icon: Icons.check_circle_outline, color: const Color(0xFF16A34A)),
            StatCard(label: 'Average default risk', value: pct(d['avg_default_probability'] as num?),
                icon: Icons.speed, color: const Color(0xFFEA580C)),
            StatCard(label: 'Officer overrides', value: pct(d['override_rate'] as num?, 0),
                icon: Icons.swap_horiz),
            StatCard(label: 'Avg time to decision',
                value: hours == null ? '-' : '${(hours as num).toStringAsFixed(0)} h', icon: Icons.timer_outlined),
          ],
        ),
        const SectionTitle('Applicant readiness mix'),
        _LightsBar(lights: lights),
        const SectionTitle('Applications, last 14 days'),
        _TrendBars(trend: (d['trend'] as List<dynamic>).cast<Map<String, dynamic>>()),
        const SectionTitle('Fairness monitor'),
        for (final f in (d['fairness'] as List<dynamic>).cast<Map<String, dynamic>>()) _FairnessCard(f: f),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            'Approval rate per group among decided applications. A ratio below 0.80 versus the '
            'best-treated group (the 4/5ths rule) is flagged for review.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const SectionTitle('Input drift (PSI vs training data)'),
        _DriftCard(drift: d['drift'] as Map<String, dynamic>),
        const SectionTitle('Decision policy'),
        Card(
          child: ListTile(
            leading: const Icon(Icons.tune),
            title: Text('Cost ratio ${settings['cost_ratio']}:1'
                '${settings['review_capacity'] != null ? ' · review cap ${pct(settings['review_capacity'] as num, 0)}' : ''}'),
            subtitle: Text('Applications scoring above ${(settings['recommendation_threshold'] as num).toStringAsFixed(3)} '
                'are recommended for review. Model suggests review for ${pct(d['review_recommended_rate'] as num?, 0)}.'),
          ),
        ),
      ],
    );
  }
}

class _LightsBar extends StatelessWidget {
  final Map<String, dynamic> lights;

  const _LightsBar({required this.lights});

  @override
  Widget build(BuildContext context) {
    final keys = const ['green', 'yellow', 'red'];
    final total = keys.fold<int>(0, (s, k) => s + (lights[k] as int));
    if (total == 0) return const Card(child: ListTile(title: Text('No applications yet.')));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Row(
                children: [
                  for (final k in keys)
                    if ((lights[k] as int) > 0)
                      Expanded(
                        flex: lights[k] as int,
                        child: Container(height: 18, color: lightStyle(k).color),
                      ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 16,
              children: [
                for (final k in keys)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    LightBadge(light: k, compact: true),
                    const SizedBox(width: 4),
                    Text('${lightStyle(k).label}: ${lights[k]} (${pct((lights[k] as int) / total, 0)})'),
                  ]),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TrendBars extends StatelessWidget {
  final List<Map<String, dynamic>> trend;

  const _TrendBars({required this.trend});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    final maxV = trend.fold<int>(1, (m, t) => (t['applications'] as int) > m ? t['applications'] as int : m);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: SizedBox(
          height: 140,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final t in trend)
                Expanded(
                  child: Tooltip(
                    message: '${shortDate(t['date'] as String)}: ${t['applications']}',
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text('${t['applications']}', style: const TextStyle(fontSize: 10)),
                        const SizedBox(height: 2),
                        Container(
                          height: 100 * (t['applications'] as int) / maxV + 2,
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          decoration: BoxDecoration(
                            color: color,
                            borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text((t['date'] as String).substring(8), style: const TextStyle(fontSize: 10)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FairnessCard extends StatelessWidget {
  final Map<String, dynamic> f;

  const _FairnessCard({required this.f});

  @override
  Widget build(BuildContext context) {
    final status = f['status'] as String;
    final groups = (f['groups'] as List<dynamic>).cast<Map<String, dynamic>>();
    final (Color color, IconData icon, String label) = switch (status) {
      'ok' => (const Color(0xFF16A34A), Icons.verified, 'Passes 4/5ths rule'),
      'check' => (const Color(0xFFEA580C), Icons.warning_amber, 'Check: below 0.80'),
      _ => (Colors.grey, Icons.hourglass_empty, 'Not enough decisions yet'),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(f['attribute'] as String, style: Theme.of(context).textTheme.titleSmall)),
                Icon(icon, color: color, size: 18),
                const SizedBox(width: 4),
                Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
              ],
            ),
            for (final g in groups)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    SizedBox(width: 90, child: Text(g['group'] as String)),
                    Expanded(
                      child: LinearProgressIndicator(
                        value: (g['approval_rate'] as num).toDouble(),
                        minHeight: 8,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    SizedBox(
                      width: 150,
                      child: Text(
                        '  ${pct(g['approval_rate'] as num, 0)} · ratio ${(g['disparate_impact'] as num).toStringAsFixed(2)}',
                        textAlign: TextAlign.right,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DriftCard extends StatelessWidget {
  final Map<String, dynamic> drift;

  const _DriftCard({required this.drift});

  @override
  Widget build(BuildContext context) {
    final status = drift['status'] as String;
    final features = (drift['features'] as List<dynamic>).cast<Map<String, dynamic>>();
    if (status == 'not enough data') {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.hourglass_empty),
          title: const Text('Not enough data yet'),
          subtitle: Text('Drift monitoring starts after ${drift['min_applications']} applications.'),
        ),
      );
    }
    final color = switch (status) {
      'stable' => const Color(0xFF16A34A),
      'moderate shift' => const Color(0xFFD97706),
      _ => const Color(0xFFDC2626),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Overall: $status (max PSI ${(drift['max_psi'] as num).toStringAsFixed(3)})',
                style: TextStyle(color: color, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            for (final f in features)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    Expanded(child: Text(f['feature'] as String)),
                    Text('${(f['psi'] as num).toStringAsFixed(3)} · ${f['status']}'),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Text('Under 0.10 stable · 0.10-0.25 moderate · over 0.25 major (consider retraining).',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
