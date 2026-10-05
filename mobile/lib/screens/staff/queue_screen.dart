import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/session.dart';
import '../../widgets/account_menu.dart';
import '../../widgets/common.dart';
import 'application_detail_screen.dart';

/// Risk-sorted application queue for loan officers.
class QueueScreen extends StatefulWidget {
  const QueueScreen({super.key});

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> {
  String _status = 'pending';
  String? _light;
  String _sort = 'risk';
  int _version = 0;

  static const _sorts = {
    'risk': 'Highest risk first',
    'newest': 'Newest first',
    'oldest': 'Oldest first',
    'amount': 'Largest amount first',
  };

  Future<Map<String, dynamic>> _load() async {
    final api = AppScope.read(context).api;
    final query = <String, String>{'sort': _sort, 'limit': '200'};
    if (_status != 'all') query['status'] = _status;
    if (_light != null) query['light'] = _light!;
    return await api.get('/org/applications', query: query) as Map<String, dynamic>;
  }

  Future<void> _open(int id) async {
    final changed = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => ApplicationDetailScreen(applicationId: id)));
    if (changed == true && mounted) setState(() => _version++);
  }

  @override
  Widget build(BuildContext context) {
    final session = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(session.orgName.isEmpty ? 'Applications' : session.orgName),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Sort',
            icon: const Icon(Icons.sort),
            initialValue: _sort,
            onSelected: (v) => setState(() => _sort = v),
            itemBuilder: (_) => [
              for (final e in _sorts.entries) PopupMenuItem(value: e.key, child: Text(e.value)),
            ],
          ),
          const AccountMenu(),
        ],
      ),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'pending', label: Text('To review')),
                    ButtonSegment(value: 'approved', label: Text('Approved')),
                    ButtonSegment(value: 'rejected', label: Text('Rejected')),
                    ButtonSegment(value: 'all', label: Text('All')),
                  ],
                  selected: {_status},
                  onSelectionChanged: (s) => setState(() => _status = s.first),
                ),
                const SizedBox(width: 12),
                for (final l in const ['green', 'yellow', 'red'])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      avatar: LightBadge(light: l, compact: true),
                      label: Text(lightStyle(l).label),
                      selected: _light == l,
                      onSelected: (on) => setState(() => _light = on ? l : null),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Loader<Map<String, dynamic>>(
              key: ValueKey('$_status|$_light|$_sort|$_version'),
              load: _load,
              builder: (context, data, reload) {
                final items = (data['items'] as List<dynamic>).cast<Map<String, dynamic>>();
                if (items.isEmpty) {
                  return const Center(child: Text('Nothing here. All caught up!'));
                }
                return RefreshIndicator(
                  onRefresh: reload,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
                    itemCount: items.length + 1,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      if (i == 0) {
                        return Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text('${data['total']} applications · ${_sorts[_sort]}',
                              style: Theme.of(context).textTheme.bodySmall),
                        );
                      }
                      final a = items[i - 1];
                      return _QueueTile(app: a, onTap: () => _open(a['id'] as int));
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _QueueTile extends StatelessWidget {
  final Map<String, dynamic> app;
  final VoidCallback onTap;

  const _QueueTile({required this.app, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final review = app['recommendation'] == 'REVIEW';
    return ListTile(
      onTap: onTap,
      leading: LightBadge(light: app['light'] as String?, compact: true),
      title: Text(app['borrower_name'] as String),
      subtitle: Text('${money(app['loan_amount'] as num)} · ${app['loan_purpose']} · '
          '${shortDate(app['created_at'] as String?)}'),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(pct(app['default_probability'] as num),
              style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          app['status'] == 'submitted' || app['status'] == 'needs_docs'
              ? Text(review ? 'Model: review' : 'Model: approve',
                  style: TextStyle(
                      fontSize: 12,
                      color: review ? const Color(0xFFEA580C) : const Color(0xFF16A34A)))
              : StatusChip(status: app['status'] as String?),
        ],
      ),
    );
  }
}
