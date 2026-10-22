import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/theme.dart';
import '../../shared/widgets/brand.dart';
import '../borrower/borrower_shell.dart';

/// Loan officer / lender admin workspace: rail on wide screens, bottom bar on phones.
class StaffShell extends ConsumerWidget {
  final Widget child;
  final String location;
  const StaffShell({super.key, required this.child, required this.location});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sessionProvider);
    final wide = MediaQuery.of(context).size.width >= 900;
    final items = [
      NavItem('/staff', context.t('nav.queue'), Icons.inbox_outlined, Icons.inbox),
      NavItem('/staff/dashboard', context.t('nav.dashboard'), Icons.insights_outlined, Icons.insights),
      NavItem('/staff/portfolio', context.t('nav.portfolio'), Icons.account_balance_wallet_outlined, Icons.account_balance_wallet),
      if (s.isAdmin && wide) NavItem('/staff/rules', context.t('nav.rules'), Icons.tune_outlined, Icons.tune),
      if (s.isAdmin && wide) NavItem('/staff/team', context.t('nav.team'), Icons.group_outlined, Icons.group),
      if (s.isAdmin && wide) NavItem('/staff/audit', context.t('nav.audit'), Icons.history_outlined, Icons.history),
      NavItem('/staff/account', context.t('nav.account'), Icons.person_outline, Icons.person),
    ];
    return AdaptiveShell(
      items: items,
      location: location,
      header: Column(children: [
        AppLogo(size: 32, showName: MediaQuery.of(context).size.width >= 1200),
        if (MediaQuery.of(context).size.width >= 1200) ...[
          const SizedBox(height: 8),
          Text(s.orgName, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Brand.muted)),
        ],
      ]),
      child: child,
    );
  }
}
