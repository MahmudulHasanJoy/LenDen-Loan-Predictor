import 'package:flutter/material.dart';

import '../core/session.dart';
import '../screens/server_screen.dart';

/// Avatar menu in the app bar: who is logged in, server settings, log out.
class AccountMenu extends StatelessWidget {
  const AccountMenu({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final initial = s.name.isEmpty ? '?' : s.name[0].toUpperCase();
    return PopupMenuButton<String>(
      tooltip: 'Account',
      icon: CircleAvatar(radius: 16, child: Text(initial)),
      onSelected: (value) {
        if (value == 'logout') {
          s.logout();
        } else if (value == 'server') {
          Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ServerScreen()));
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem<String>(
          enabled: false,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(s.name),
            subtitle: Text([_roleLabel(s.role), if (s.orgName.isNotEmpty) s.orgName].join(' · ')),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(value: 'server', child: Text('Server settings')),
        const PopupMenuItem<String>(value: 'logout', child: Text('Log out')),
      ],
    );
  }

  static String _roleLabel(String? role) => switch (role) {
        'borrower' => 'Borrower',
        'officer' => 'Loan officer',
        'admin' => 'Lender admin',
        'superadmin' => 'Platform owner',
        _ => '',
      };
}
