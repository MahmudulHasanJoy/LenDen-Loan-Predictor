import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../core/theme.dart';
import '../../widgets/brand.dart';
import 'audit_screen.dart';
import 'dashboard_screen.dart';
import 'org_settings_screen.dart';
import 'queue_screen.dart';
import 'team_screen.dart';

class _Page {
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final Widget Function() build;
  const _Page(this.label, this.icon, this.selectedIcon, this.build);
}

/// Loan officer / lender admin workspace.
/// Wide screens (web, tablet): SaaS-style sidebar. Phones: bottom navigation.
class StaffShell extends StatefulWidget {
  const StaffShell({super.key});

  @override
  State<StaffShell> createState() => _StaffShellState();
}

class _StaffShellState extends State<StaffShell> {
  int _index = 0;

  List<_Page> _pages(bool admin) => [
        _Page('Applications', Icons.inbox_outlined, Icons.inbox, () => const QueueScreen()),
        _Page('Dashboard', Icons.insights_outlined, Icons.insights, () => const DashboardScreen()),
        if (admin) _Page('Team', Icons.group_outlined, Icons.group, () => const TeamScreen()),
        if (admin) _Page('Decision rules', Icons.tune_outlined, Icons.tune, () => const OrgSettingsScreen()),
        if (admin) _Page('Activity log', Icons.history_outlined, Icons.history, () => const AuditScreen()),
      ];

  @override
  Widget build(BuildContext context) {
    final session = AppScope.of(context);
    final pages = _pages(session.isAdmin);
    final index = _index.clamp(0, pages.length - 1);
    final body = KeyedSubtree(key: ValueKey(index), child: pages[index].build());

    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth >= 900) {
        return Scaffold(
          body: Row(
            children: [
              _Sidebar(
                pages: pages,
                index: index,
                onSelect: (i) => setState(() => _index = i),
                session: session,
              ),
              VerticalDivider(width: 1, color: Theme.of(context).colorScheme.outlineVariant),
              Expanded(child: body),
            ],
          ),
        );
      }
      return Scaffold(
        body: body,
        bottomNavigationBar: NavigationBar(
          selectedIndex: index,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: [
            for (final p in pages)
              NavigationDestination(
                  icon: Icon(p.icon), selectedIcon: Icon(p.selectedIcon), label: p.label.split(' ').first),
          ],
        ),
      );
    });
  }
}

class _Sidebar extends StatelessWidget {
  final List<_Page> pages;
  final int index;
  final ValueChanged<int> onSelect;
  final Session session;

  const _Sidebar({required this.pages, required this.index, required this.onSelect, required this.session});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      width: 248,
      color: scheme.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(Space.lg + 4, Space.lg, Space.lg, Space.sm),
              child: AppLogo(size: 30),
            ),
            Container(
              margin: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.md, Space.md),
              padding: const EdgeInsets.all(Space.md),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Row(
                children: [
                  const IconTile(icon: Icons.account_balance, color: Brand.primary, size: 32),
                  const SizedBox(width: Space.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(session.orgName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700)),
                        Text(((session.org?['plan'] as String?) ?? '').toUpperCase(),
                            style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            for (var i = 0; i < pages.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: 2),
                child: ListTile(
                  dense: true,
                  selected: i == index,
                  selectedTileColor: scheme.primary.withValues(alpha: 0.10),
                  leading: Icon(i == index ? pages[i].selectedIcon : pages[i].icon),
                  title: Text(pages[i].label,
                      style: TextStyle(fontWeight: i == index ? FontWeight.w700 : FontWeight.w500)),
                  onTap: () => onSelect(i),
                ),
              ),
            const Spacer(),
            const Divider(),
            ListTile(
              leading: CircleAvatar(
                radius: 16,
                child: Text(session.name.isEmpty ? '?' : session.name[0].toUpperCase()),
              ),
              title: Text(session.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(session.isAdmin ? 'Admin' : 'Loan officer'),
              trailing: IconButton(
                tooltip: 'Log out',
                icon: const Icon(Icons.logout),
                onPressed: session.logout,
              ),
            ),
            const SizedBox(height: Space.sm),
          ],
        ),
      ),
    );
  }
}
