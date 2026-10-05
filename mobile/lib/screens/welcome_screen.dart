import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../widgets/brand.dart';
import 'auth/login_screen.dart';
import 'auth/register_screen.dart';
import 'borrower/check_screen.dart';
import 'server_screen.dart';

/// Public landing page: hero, primary call to action, how it works, who it is for.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  void _go(BuildContext context, Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          // ------------------------------------------------------------------ hero
          Container(
            decoration: const BoxDecoration(gradient: Brand.heroGradient),
            child: SafeArea(
              bottom: false,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(Space.xl, Space.md, Space.xl, Space.xxl + 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const AppLogo(size: 32, nameColor: Colors.white),
                            const Spacer(),
                            IconButton(
                              tooltip: 'Server settings',
                              color: Colors.white70,
                              icon: const Icon(Icons.dns_outlined),
                              onPressed: () => _go(context, const ServerScreen()),
                            ),
                            TextButton(
                              style: TextButton.styleFrom(foregroundColor: Colors.white),
                              onPressed: () => _go(context, const LoginScreen()),
                              child: const Text('Log in'),
                            ),
                          ],
                        ),
                        const SizedBox(height: Space.xxl),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Text('Free for borrowers',
                              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 12)),
                        ),
                        const SizedBox(height: Space.md),
                        Text('Know if you are ready for a loan before you apply.',
                            style: theme.textTheme.headlineMedium?.copyWith(color: Colors.white, height: 1.15)),
                        const SizedBox(height: Space.md),
                        Text(
                          'Get a clear readiness score, see exactly what to change, and apply to '
                          'lenders in one place.',
                          style: theme.textTheme.bodyLarge?.copyWith(color: Colors.white70),
                        ),
                        const SizedBox(height: Space.xl),
                        FilledButton.icon(
                          key: const Key('check-readiness'),
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: Brand.primaryDark,
                            minimumSize: const Size.fromHeight(54),
                          ),
                          icon: const Icon(Icons.speed),
                          label: const Text('Check my readiness, free'),
                          onPressed: () => _go(context, const CheckScreen()),
                        ),
                        const SizedBox(height: Space.sm),
                        const Center(
                          child: Text('About 1 minute · no sign-up · nothing is stored',
                              style: TextStyle(color: Colors.white60, fontSize: 12)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          // ------------------------------------------------------------------ how it works
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Padding(
                padding: const EdgeInsets.all(Space.xl),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('How it works', style: theme.textTheme.titleLarge),
                    const SizedBox(height: Space.md),
                    const _Step(n: 1, icon: Icons.edit_note, title: 'Answer a few questions',
                        text: 'Income, loan amount, job and existing debts.'),
                    const _Step(n: 2, icon: Icons.traffic_outlined, title: 'Get your readiness light',
                        text: 'Green, yellow or red, with your estimated risk.'),
                    const _Step(n: 3, icon: Icons.lightbulb_outline, title: 'See what to change',
                        text: 'Concrete tips like a smaller amount or adding a co-signer.'),
                    const _Step(n: 4, icon: Icons.send_outlined, title: 'Apply when ready',
                        text: 'Send your application to a lender and track the decision.'),
                    const SizedBox(height: Space.xl),
                    Text('Built for every side of lending', style: theme.textTheme.titleLarge),
                    const SizedBox(height: Space.md),
                    const _Audience(icon: Icons.person_outline, color: Brand.primary, title: 'Borrowers',
                        text: 'Readiness check, improvement plan, EMI calculator, application tracking.'),
                    const _Audience(icon: Icons.badge_outlined, color: Brand.info, title: 'Loan officers',
                        text: 'Risk-sorted queue with the reasons behind every score. People decide.'),
                    const _Audience(icon: Icons.insights_outlined, color: Brand.warning, title: 'Lender admins',
                        text: 'Cost settings, review capacity, team, fairness and drift monitoring.'),
                    const SizedBox(height: Space.xl),
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                      onPressed: () => _go(context, const RegisterScreen()),
                      child: const Text('Create a free borrower account'),
                    ),
                    const SizedBox(height: Space.lg),
                    Text(
                      'Educational project. Scores come from a model trained on public synthetic data '
                      'and are not lending decisions.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  final int n;
  final IconData icon;
  final String title;
  final String text;

  const _Step({required this.n, required this.icon, required this.title, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: Brand.primary.withValues(alpha: 0.12),
            child: Text('$n', style: const TextStyle(color: Brand.primary, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                Text(text, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          Icon(icon, color: Brand.muted, size: 20),
        ],
      ),
    );
  }
}

class _Audience extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String text;

  const _Audience({required this.icon, required this.color, required this.title, required this.text});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Row(
          children: [
            IconTile(icon: icon, color: color),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(text, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
