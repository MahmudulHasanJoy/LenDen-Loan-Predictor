import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/session.dart';
import '../../core/l10n/l10n.dart';
import '../../shared/widgets/brand.dart';

class NavItem {
  final String path;
  final String label;
  final IconData icon;
  final IconData selected;
  const NavItem(this.path, this.label, this.icon, this.selected);
}

int navIndex(List<NavItem> items, String location) {
  var best = 0;
  var bestLen = -1;
  for (var i = 0; i < items.length; i++) {
    final p = items[i].path;
    final match = location == p || location.startsWith('$p/');
    if (match && p.length > bestLen) {
      best = i;
      bestLen = p.length;
    }
  }
  return best;
}

/// Bottom navigation on phones, a navigation rail on wide screens.
class AdaptiveShell extends ConsumerWidget {
  final List<NavItem> items;
  final Widget child;
  final String location;
  final Widget? header;
  final int badgeIndex;
  final int badgeCount;

  const AdaptiveShell(
      {super.key,
      required this.items,
      required this.child,
      required this.location,
      this.header,
      this.badgeIndex = -1,
      this.badgeCount = 0});

  Widget _icon(int i, IconData icon) => i == badgeIndex && badgeCount > 0
      ? Badge(label: Text(badgeCount > 99 ? '99+' : '$badgeCount'), child: Icon(icon))
      : Icon(icon);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = navIndex(items, location);
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth >= 900) {
        return Scaffold(
          body: Row(children: [
            NavigationRail(
              extended: c.maxWidth >= 1200,
              minExtendedWidth: 220,
              selectedIndex: index,
              leading: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: header ?? AppLogo(size: 32, showName: c.maxWidth >= 1200),
              ),
              onDestinationSelected: (i) => context.go(items[i].path),
              destinations: [
                for (var i = 0; i < items.length; i++)
                  NavigationRailDestination(
                      icon: _icon(i, items[i].icon), selectedIcon: _icon(i, items[i].selected), label: Text(items[i].label)),
              ],
            ),
            VerticalDivider(width: 1, color: Theme.of(context).colorScheme.outlineVariant),
            Expanded(child: child),
          ]),
        );
      }
      return Scaffold(
        body: child,
        bottomNavigationBar: NavigationBar(
          selectedIndex: index,
          onDestinationSelected: (i) => context.go(items[i].path),
          destinations: [
            for (var i = 0; i < items.length; i++)
              NavigationDestination(icon: _icon(i, items[i].icon), selectedIcon: _icon(i, items[i].selected), label: items[i].label),
          ],
        ),
      );
    });
  }
}

class BorrowerShell extends ConsumerWidget {
  final Widget child;
  final String location;
  const BorrowerShell({super.key, required this.child, required this.location});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(sessionProvider.select((s) => s.unread));
    final items = [
      NavItem('/home', context.t('nav.home'), Icons.home_outlined, Icons.home),
      NavItem('/applications', context.t('nav.applications'), Icons.description_outlined, Icons.description),
      NavItem('/loans', context.t('nav.loans'), Icons.account_balance_wallet_outlined, Icons.account_balance_wallet),
      NavItem('/inbox', context.t('nav.inbox'), Icons.notifications_none, Icons.notifications),
      NavItem('/account', context.t('nav.account'), Icons.person_outline, Icons.person),
    ];
    return AdaptiveShell(items: items, location: location, badgeIndex: 3, badgeCount: unread, child: child);
  }
}
