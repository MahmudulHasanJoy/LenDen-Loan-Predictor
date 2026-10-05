import 'package:flutter/material.dart';

import 'core/session.dart';
import 'core/theme.dart';
import 'screens/borrower/borrower_home.dart';
import 'screens/staff/staff_shell.dart';
import 'screens/superadmin/super_console.dart';
import 'screens/welcome_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final session = await Session.restore();
  runApp(LenDenApp(session: session));
}

class LenDenApp extends StatelessWidget {
  final Session session;

  const LenDenApp({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    return AppScope(
      session: session,
      child: MaterialApp(
        title: 'LenDen',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        home: const RoleRouter(),
      ),
    );
  }
}

/// Picks the shell for whoever is logged in. Same app, different panel per role.
class RoleRouter extends StatelessWidget {
  const RoleRouter({super.key});

  @override
  Widget build(BuildContext context) {
    final session = AppScope.of(context);
    switch (session.role) {
      case 'borrower':
        return const BorrowerHome();
      case 'officer':
      case 'admin':
        return const StaffShell();
      case 'superadmin':
        return const SuperConsole();
      default:
        return const WelcomeScreen();
    }
  }
}
