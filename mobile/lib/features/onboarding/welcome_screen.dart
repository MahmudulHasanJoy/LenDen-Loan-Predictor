import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/session.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/theme.dart';
import '../../shared/widgets/brand.dart';
import '../../shared/widgets/common.dart';

/// First screen: what LenDen does, in the user's language, with one clear action.
class WelcomeScreen extends ConsumerWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final hasDraft = ref.watch(prefsProvider).getInt(Keys.draftId) != null;
    final wide = MediaQuery.of(context).size.width >= 900;
    final steps = [
      (Icons.edit_note_rounded, 'welcome.step1', 'welcome.step1_sub'),
      (Icons.insights_rounded, 'welcome.step2', 'welcome.step2_sub'),
      (Icons.storefront_rounded, 'welcome.step3', 'welcome.step3_sub'),
      (Icons.stairs_rounded, 'welcome.step4', 'welcome.step4_sub'),
    ];
    return Scaffold(
      body: SingleChildScrollView(
        child: Column(children: [
          Container(
            width: double.infinity,
            decoration: const BoxDecoration(gradient: Brand.heroGradient),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
                child: MaxWidth(
                  width: 1040,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      const AppLogo(size: 34, nameColor: Colors.white),
                      const Spacer(),
                      const LanguageToggle(onDark: true),
                      const SizedBox(width: 8),
                      TextButton(
                        style: TextButton.styleFrom(foregroundColor: Colors.white),
                        onPressed: () => context.go('/login'),
                        child: Text(context.t('welcome.login')),
                      ),
                    ]),
                    SizedBox(height: wide ? 56 : 36),
                    Text(context.t('welcome.headline'),
                        style: theme.textTheme.displaySmall?.copyWith(
                            color: Colors.white, fontWeight: FontWeight.w800, letterSpacing: -1, height: 1.1)),
                    const SizedBox(height: 14),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Text(context.t('welcome.sub'),
                          style: theme.textTheme.titleMedium?.copyWith(color: Colors.white70, fontWeight: FontWeight.w400)),
                    ),
                    const SizedBox(height: 24),
                    Wrap(spacing: 12, runSpacing: 12, children: [
                      FilledButton.icon(
                        style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Brand.primaryDark),
                        onPressed: () => context.go('/check'),
                        icon: const Icon(Icons.bolt_rounded),
                        label: Text(hasDraft ? context.t('welcome.continue') : context.t('welcome.cta')),
                      ),
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white54)),
                        onPressed: () => context.go('/register'),
                        child: Text(context.t('welcome.create')),
                      ),
                    ]),
                    const SizedBox(height: 16),
                    Wrap(spacing: 16, runSpacing: 8, children: [
                      for (final k in ['welcome.badge1', 'welcome.badge2', 'welcome.badge3'])
                        Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.check_circle, size: 16, color: Brand.accent),
                          const SizedBox(width: 6),
                          Text(context.t(k), style: const TextStyle(color: Colors.white70)),
                        ]),
                    ]),
                  ]),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 28, 20, 8),
            child: MaxWidth(
              width: 1040,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(context.t('welcome.how'), style: theme.textTheme.titleLarge),
                const SizedBox(height: 12),
                Wrap(spacing: 12, runSpacing: 12, children: [
                  for (var i = 0; i < steps.length; i++)
                    SizedBox(
                      width: wide ? 245 : double.infinity,
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            IconTile(icon: steps[i].$1, color: theme.colorScheme.primary),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text('${context.digits(i + 1)}. ${context.t(steps[i].$2)}', style: theme.textTheme.titleSmall),
                                const SizedBox(height: 4),
                                Text(context.t(steps[i].$3), style: theme.textTheme.bodySmall),
                              ]),
                            ),
                          ]),
                        ),
                      ),
                    ),
                ]),
                const SizedBox(height: 24),
                Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    leading: IconTile(icon: Icons.account_balance_outlined, color: Brand.info),
                    title: Text(context.t('welcome.lenders')),
                    subtitle: Text(context.t('welcome.lenders_sub')),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.go('/login'),
                  ),
                ),
                const SizedBox(height: 16),
                Text(context.t('welcome.disclaimer'), style: theme.textTheme.bodySmall),
                const SizedBox(height: 24),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}
