import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/auth/session.dart';
import '../../core/format.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/theme.dart';

/// A readable message for any error, translated when the API sent a known code.
String errorText(BuildContext context, Object error) {
  if (error is ApiException) {
    if (error.code != null && L10n.has('error.${error.code}')) {
      return context.t('error.${error.code}', error.fields.map((k, v) => MapEntry(k, v is num ? context.num0(v) : v)));
    }
    if (error.offline) return context.t('error.offline');
    return error.message;
  }
  return error.toString();
}

void showError(BuildContext context, Object error) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(errorText(context, error))));
}

void showInfo(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Loading / error / data for a Riverpod AsyncValue, with a retry button.
class AsyncView<T> extends ConsumerWidget {
  final AsyncValue<T> value;
  final Widget Function(T data) builder;
  final VoidCallback onRetry;

  const AsyncView({super.key, required this.value, required this.builder, required this.onRetry});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return value.when(
      skipLoadingOnRefresh: true,
      skipLoadingOnReload: true,
      data: builder,
      loading: () => const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator())),
      error: (e, _) => ErrorRetry(error: e, onRetry: onRetry),
    );
  }
}

class ErrorRetry extends ConsumerWidget {
  final Object error;
  final VoidCallback onRetry;

  const ErrorRetry({super.key, required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expired = error is ApiException && (error as ApiException).unauthorized;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(expired ? Icons.lock_clock_outlined : Icons.cloud_off_outlined, size: 44, color: Brand.muted),
            const SizedBox(height: 12),
            Text(errorText(context, error), textAlign: TextAlign.center),
            const SizedBox(height: 16),
            expired
                ? FilledButton(
                    onPressed: () => ref.read(sessionProvider.notifier).logout(), child: Text(context.t('auth.login_again')))
                : FilledButton.tonal(onPressed: onRetry, child: Text(context.t('common.retry'))),
          ],
        ),
      ),
    );
  }
}

/// Keeps content readable on tablets and web by capping its width.
class MaxWidth extends StatelessWidget {
  final double width;
  final Widget child;

  const MaxWidth({super.key, this.width = 760, required this.child});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(constraints: BoxConstraints(maxWidth: width), child: child),
    );
  }
}

/// Standard scrollable page body with a max width and pull-to-refresh.
class PageList extends StatelessWidget {
  final List<Widget> children;
  final Future<void> Function()? onRefresh;
  final double width;
  final EdgeInsets padding;

  const PageList(
      {super.key,
      required this.children,
      this.onRefresh,
      this.width = 760,
      this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 32)});

  @override
  Widget build(BuildContext context) {
    final list = ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: padding,
      children: [MaxWidth(width: width, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children))],
    );
    return onRefresh == null ? list : RefreshIndicator(onRefresh: onRefresh!, child: list);
  }
}

class Pill extends StatelessWidget {
  final String label;
  final Color color;
  final IconData? icon;
  final bool dense;

  const Pill({super.key, required this.label, required this.color, this.icon, this.dense = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 8 : 10, vertical: dense ? 2 : 4),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, color: color, size: dense ? 13 : 15), const SizedBox(width: 4)],
          Text(label,
              style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: dense ? 12 : 13)),
        ],
      ),
    );
  }
}

/// Application / loan / repayment status as a coloured pill.
class StatusChip extends StatelessWidget {
  final String? status;
  final bool dense;

  const StatusChip({super.key, required this.status, this.dense = false});

  @override
  Widget build(BuildContext context) {
    final color = statusColors[status] ?? Brand.muted;
    return Pill(label: context.code('status', status), color: color, dense: dense);
  }
}

class LightBadge extends StatelessWidget {
  final String? light;
  const LightBadge({super.key, required this.light});

  @override
  Widget build(BuildContext context) {
    final color = lightColors[light] ?? Brand.muted;
    return Pill(label: context.code('light', light), color: color, icon: Icons.circle, dense: true);
  }
}

class StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color? color;
  final String? caption;
  final double width;

  const StatCard(
      {super.key, required this.label, required this.value, required this.icon, this.color, this.caption, this.width = 210});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = color ?? theme.colorScheme.primary;
    return SizedBox(
      width: width,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(child: Text(label, style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600))),
                IconTile(icon: icon, color: c, size: 32),
              ]),
              const SizedBox(height: 10),
              Text(value, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.5)),
              if (caption != null) Text(caption!, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  final String text;
  final Widget? trailing;

  const SectionTitle(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Row(children: [
        Expanded(child: Text(text, style: Theme.of(context).textTheme.titleMedium)),
        if (trailing != null) trailing!,
      ]),
    );
  }
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
      child: Column(children: [
        IconTile(icon: icon, color: theme.colorScheme.primary, size: 56),
        const SizedBox(height: 14),
        Text(title, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
        if (message != null) ...[
          const SizedBox(height: 6),
          Text(message!, style: theme.textTheme.bodyMedium?.copyWith(color: Brand.muted), textAlign: TextAlign.center),
        ],
        if (action != null) ...[const SizedBox(height: 16), action!],
      ]),
    );
  }
}

/// Small tinted square holding an icon (KPI cards, lists).
class IconTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;

  const IconTile({super.key, required this.icon, required this.color, this.size = 40});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(size * 0.3)),
      child: Icon(icon, color: color, size: size * 0.55),
    );
  }
}

/// A label/value row used in detail cards.
class KeyValue extends StatelessWidget {
  final String label;
  final String value;
  final bool strong;

  const KeyValue(this.label, this.value, {super.key, this.strong = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        Expanded(child: Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: Brand.muted))),
        const SizedBox(width: 12),
        Flexible(
          child: Text(value,
              textAlign: TextAlign.right,
              style: strong ? theme.textTheme.titleMedium : theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }
}

/// Runs an async action with a busy flag and shows errors as a snackbar.
Future<T?> runBusy<T>(BuildContext context, Future<T> Function() action, {void Function(bool)? busy}) async {
  busy?.call(true);
  try {
    return await action();
  } catch (e) {
    if (context.mounted) showError(context, e);
    return null;
  } finally {
    busy?.call(false);
  }
}
