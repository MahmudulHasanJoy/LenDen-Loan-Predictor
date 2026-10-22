import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/auth/session.dart';
import '../features/account/account_screen.dart';
import '../features/applications/applications_screens.dart';
import '../features/auth/login_screen.dart';
import '../features/auth/password_screens.dart';
import '../features/auth/register_screen.dart';
import '../features/borrower/borrower_home.dart';
import '../features/borrower/borrower_shell.dart';
import '../features/loans/loans_screens.dart';
import '../features/notifications/inbox_screen.dart';
import '../features/offers/offers_screen.dart';
import '../features/onboarding/server_screen.dart';
import '../features/onboarding/welcome_screen.dart';
import '../features/platform/platform_screens.dart';
import '../features/readiness/result_screen.dart';
import '../features/readiness/wizard_screen.dart';
import '../features/staff/admin_screens.dart';
import '../features/staff/insights_screens.dart';
import '../features/staff/queue_screen.dart';
import '../features/staff/staff_application_screen.dart';
import '../features/staff/staff_shell.dart';

/// Rebuilds routes when the session changes (log in, log out, expiry).
class _SessionListenable extends ChangeNotifier {
  _SessionListenable(Ref ref) {
    ref.listen<SessionState>(sessionProvider, (prev, next) {
      if (prev?.role != next.role) notifyListeners();
    });
  }
}

const _public = ['/', '/check', '/offers', '/login', '/register', '/forgot', '/reset', '/server'];

bool _isPublic(String path) => _public.any((p) => path == p || (p != '/' && path.startsWith('$p/')));

String? _area(String path) {
  if (path == '/staff' || path.startsWith('/staff/')) return 'staff';
  if (path == '/platform' || path.startsWith('/platform/')) return 'platform';
  if (_isPublic(path)) return null;
  return 'borrower';
}

int? _id(GoRouterState s) => int.tryParse(s.pathParameters['id'] ?? '');

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _SessionListenable(ref);
  ref.onDispose(refresh.dispose);
  return GoRouter(
    initialLocation: '/',
    refreshListenable: refresh,
    redirect: (context, state) {
      final s = ref.read(sessionProvider);
      final path = state.uri.path;
      final area = _area(path);
      if (!s.loggedIn) {
        if (area == null) return null;
        return Uri(path: '/login', queryParameters: {'from': state.uri.toString()}).toString();
      }
      // Logged in: keep each role in its own area.
      if (path == '/' || path == '/login' || path == '/register') return s.homePath;
      final mine = s.isBorrower ? 'borrower' : (s.isStaff ? 'staff' : 'platform');
      if (area != null && area != mine) return s.homePath;
      if (!s.isBorrower && (path == '/check' || path.startsWith('/check/') || path == '/offers')) return s.homePath;
      return null;
    },
    routes: [
      GoRoute(path: '/', builder: (c, s) => const WelcomeScreen()),
      GoRoute(path: '/server', builder: (c, s) => const ServerScreen()),
      GoRoute(path: '/login', builder: (c, s) => LoginScreen(from: s.uri.queryParameters['from'])),
      GoRoute(path: '/register', builder: (c, s) => RegisterScreen(from: s.uri.queryParameters['from'])),
      GoRoute(path: '/forgot', builder: (c, s) => const ForgotPasswordScreen()),
      GoRoute(path: '/reset', builder: (c, s) => ResetPasswordScreen(token: s.uri.queryParameters['token'] ?? '')),
      GoRoute(
        path: '/check',
        builder: (c, s) => WizardScreen(startStep: int.tryParse(s.uri.queryParameters['step'] ?? '')),
        routes: [GoRoute(path: 'result', builder: (c, s) => const ResultScreen())],
      ),
      GoRoute(path: '/offers', builder: (c, s) => const OffersScreen()),
      ShellRoute(
        builder: (c, s, child) => BorrowerShell(location: s.uri.path, child: child),
        routes: [
          GoRoute(path: '/home', builder: (c, s) => const BorrowerHomeScreen()),
          GoRoute(
            path: '/applications',
            builder: (c, s) => const MyApplicationsScreen(),
            routes: [GoRoute(path: ':id', builder: (c, s) => ApplicationDetailScreen(id: _id(s) ?? 0))],
          ),
          GoRoute(
            path: '/loans',
            builder: (c, s) => const LoansScreen(),
            routes: [GoRoute(path: ':id', builder: (c, s) => LoanDetailScreen(id: _id(s) ?? 0))],
          ),
          GoRoute(path: '/inbox', builder: (c, s) => const InboxScreen()),
          GoRoute(path: '/account', builder: (c, s) => const AccountScreen()),
        ],
      ),
      ShellRoute(
        builder: (c, s, child) => StaffShell(location: s.uri.path, child: child),
        routes: [
          GoRoute(
            path: '/staff',
            builder: (c, s) => const QueueScreen(),
            routes: [
              GoRoute(path: 'applications/:id', builder: (c, s) => StaffApplicationScreen(id: _id(s) ?? 0)),
              GoRoute(path: 'dashboard', builder: (c, s) => const DashboardScreen()),
              GoRoute(path: 'portfolio', builder: (c, s) => const PortfolioScreen()),
              GoRoute(path: 'rules', builder: (c, s) => const RulesScreen()),
              GoRoute(path: 'team', builder: (c, s) => const TeamScreen()),
              GoRoute(path: 'audit', builder: (c, s) => const AuditScreen()),
              GoRoute(path: 'inbox', builder: (c, s) => const InboxScreen(basePath: '/staff')),
              GoRoute(path: 'account', builder: (c, s) => const AccountScreen()),
            ],
          ),
        ],
      ),
      ShellRoute(
        builder: (c, s, child) => PlatformShell(location: s.uri.path, child: child),
        routes: [
          GoRoute(
            path: '/platform',
            builder: (c, s) => const PlatformOverviewScreen(),
            routes: [
              GoRoute(path: 'lenders', builder: (c, s) => const OrgsScreen()),
              GoRoute(path: 'models', builder: (c, s) => const ModelsScreen()),
              GoRoute(path: 'settings', builder: (c, s) => const PlatformSettingsScreen()),
              GoRoute(path: 'account', builder: (c, s) => const AccountScreen()),
            ],
          ),
        ],
      ),
    ],
  );
});
