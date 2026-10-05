import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/session.dart';
import '../../widgets/account_menu.dart';
import '../../widgets/common.dart';

class MyApplicationsScreen extends StatelessWidget {
  const MyApplicationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My applications'), actions: const [AccountMenu()]),
      body: Loader<List<dynamic>>(
        load: () async => await AppScope.read(context).api.get('/applications/mine') as List<dynamic>,
        builder: (context, apps, reload) {
          if (apps.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text('No applications yet. Run a readiness check and apply when you are ready.',
                    textAlign: TextAlign.center),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: reload,
            child: MaxWidth(
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: apps.length,
                itemBuilder: (context, i) => _ApplicationCard(app: apps[i] as Map<String, dynamic>),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ApplicationCard extends StatelessWidget {
  final Map<String, dynamic> app;

  const _ApplicationCard({required this.app});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final note = app['decision_note'] as String?;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(app['lender'] as String, style: theme.textTheme.titleMedium)),
                StatusChip(status: app['status'] as String?),
              ],
            ),
            const SizedBox(height: 6),
            Text('${money(app['loan_amount'] as num)} · ${app['loan_purpose']} · '
                'applied ${shortDate(app['created_at'] as String?)}'),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('Readiness when applied: '),
                LightBadge(light: app['light'] as String?),
              ],
            ),
            if (note != null && note.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('Message from the lender: $note'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
