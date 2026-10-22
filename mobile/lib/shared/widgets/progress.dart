import 'package:flutter/material.dart';

import '../../core/l10n/l10n.dart';

/// "Step 2 of 4" with a segmented bar.
class StepProgress extends StatelessWidget {
  final int step; // 1-based
  final int total;
  final List<String> labels;

  const StepProgress({super.key, required this.step, required this.total, this.labels = const []});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(context.t('wizard.step_of', {'step': context.digits(step), 'total': context.digits(total)}),
          style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      Row(children: [
        for (var i = 1; i <= total; i++)
          Expanded(
            child: Container(
              height: 6,
              margin: EdgeInsets.only(right: i < total ? 6 : 0),
              decoration: BoxDecoration(
                color: i <= step ? theme.colorScheme.primary : theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
      ]),
      if (labels.length == total) ...[
        const SizedBox(height: 6),
        Text(labels[step - 1], style: theme.textTheme.titleMedium),
      ],
    ]);
  }
}

/// Status timeline: Submitted -> In review -> Documents -> Decision.
class StatusTimeline extends StatelessWidget {
  final List<Map<String, dynamic>> events;
  const StatusTimeline({super.key, required this.events});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(children: [
      for (var i = 0; i < events.length; i++)
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(
              width: 28,
              child: Column(children: [
                Container(
                  width: 14,
                  height: 14,
                  margin: const EdgeInsets.only(top: 4),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i == events.length - 1 ? theme.colorScheme.primary : theme.colorScheme.primary.withValues(alpha: 0.4),
                  ),
                ),
                if (i < events.length - 1)
                  Expanded(child: Container(width: 2, color: theme.colorScheme.outlineVariant)),
              ]),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 16, left: 4),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(context.code('status', events[i]['to_status'] as String?), style: theme.textTheme.titleSmall),
                  Text(
                      [
                        context.dateTime(events[i]['created_at'] as String?),
                        if (events[i]['actor_role'] != null && events[i]['actor_role'] != 'borrower')
                          context.code('role', events[i]['actor_role'] as String?),
                      ].join(' · '),
                      style: theme.textTheme.bodySmall),
                  if ((events[i]['note'] as String?)?.isNotEmpty ?? false)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('"${events[i]['note']}"', style: theme.textTheme.bodyMedium),
                    ),
                ]),
              ),
            ),
          ]),
        ),
    ]);
  }
}
