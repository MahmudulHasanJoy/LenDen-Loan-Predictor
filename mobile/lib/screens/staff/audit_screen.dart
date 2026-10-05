import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/session.dart';
import '../../widgets/account_menu.dart';
import '../../widgets/common.dart';

/// Who did what, when: decisions, settings changes and team changes.
class AuditScreen extends StatelessWidget {
  const AuditScreen({super.key});

  static IconData _icon(String action) {
    if (action.contains('approved')) return Icons.check_circle_outline;
    if (action.contains('rejected')) return Icons.cancel_outlined;
    if (action.contains('needs_docs')) return Icons.upload_file;
    if (action.startsWith('settings')) return Icons.tune;
    if (action.startsWith('team')) return Icons.group_outlined;
    return Icons.description_outlined;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Activity log'), actions: const [AccountMenu()]),
      body: Loader<List<dynamic>>(
        load: () async =>
            await AppScope.read(context).api.get('/org/audit', query: {'limit': '100'}) as List<dynamic>,
        builder: (context, log, reload) => RefreshIndicator(
          onRefresh: reload,
          child: MaxWidth(
            child: ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: log.length,
              itemBuilder: (context, i) {
                final e = log[i] as Map<String, dynamic>;
                final action = e['action'] as String;
                return ListTile(
                  leading: Icon(_icon(action)),
                  title: Text('${e['user_name'] ?? 'System'} · ${action.replaceAll('.', ' ').replaceAll('_', ' ')}'),
                  subtitle: Text('${e['target'] ?? ''} · ${shortDate(e['created_at'] as String?)}'),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
