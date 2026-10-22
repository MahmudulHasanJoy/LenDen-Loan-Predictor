import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/theme/theme.dart';

/// Logo mark + wordmark.
class AppLogo extends StatelessWidget {
  final double size;
  final bool showName;
  final Color? nameColor;

  const AppLogo({super.key, this.size = 36, this.showName = true, this.nameColor});

  @override
  Widget build(BuildContext context) {
    final mark = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Brand.accent, Brand.primary]),
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: Icon(Icons.swap_horiz_rounded, color: Colors.white, size: size * 0.66),
    );
    if (!showName) return mark;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      mark,
      SizedBox(width: size * 0.3),
      Text('LenDen',
          style: TextStyle(
              fontSize: size * 0.55,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
              color: nameColor ?? Theme.of(context).colorScheme.onSurface)),
    ]);
  }
}

/// Large page heading with optional subtitle and trailing action.
class PageHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;

  const PageHeader({super.key, required this.title, this.subtitle, this.trailing});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.xs, Space.sm, Space.xs, Space.lg),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: theme.textTheme.headlineSmall),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(subtitle!, style: theme.textTheme.bodyMedium?.copyWith(color: Brand.muted)),
            ],
          ]),
        ),
        if (trailing != null) trailing!,
      ]),
    );
  }
}

/// বাংলা / English switch, shown on the first screen and in the account page.
class LanguageToggle extends ConsumerWidget {
  final bool onDark;
  const LanguageToggle({super.key, this.onDark = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final code = ref.watch(localeProvider).languageCode;
    final fg = onDark ? Colors.white : Theme.of(context).colorScheme.onSurface;
    return SegmentedButton<String>(
      showSelectedIcon: false,
      style: SegmentedButton.styleFrom(
        foregroundColor: fg,
        selectedForegroundColor: onDark ? Brand.ink : Theme.of(context).colorScheme.onPrimaryContainer,
        selectedBackgroundColor: onDark ? Colors.white : Theme.of(context).colorScheme.primaryContainer,
        side: BorderSide(color: onDark ? Colors.white54 : Theme.of(context).colorScheme.outlineVariant),
        visualDensity: VisualDensity.compact,
      ),
      segments: const [
        ButtonSegment(value: 'bn', label: Text('বাংলা')),
        ButtonSegment(value: 'en', label: Text('English')),
      ],
      selected: {code},
      onSelectionChanged: (s) => ref.read(localeProvider.notifier).set(s.first),
    );
  }
}
