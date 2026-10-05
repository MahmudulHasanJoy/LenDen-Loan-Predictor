import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

/// Who is logged in. Rebuilds the app shell when it changes.
class Session extends ChangeNotifier {
  static const _kUrl = 'api_base_url';
  static const _kToken = 'auth_token';

  final Api api;
  Map<String, dynamic>? user;
  Map<String, dynamic>? org;

  Session(this.api);

  bool get loggedIn => user != null;
  String? get role => user?['role'] as String?;
  String get name => (user?['name'] as String?) ?? '';
  String get orgName => (org?['name'] as String?) ?? '';
  bool get isAdmin => role == 'admin';

  static Future<Session> restore() async {
    final prefs = await SharedPreferences.getInstance();
    final api = Api(baseUrl: prefs.getString(_kUrl) ?? Api.platformDefaultUrl);
    final session = Session(api);
    final token = prefs.getString(_kToken);
    if (token != null) {
      api.token = token;
      try {
        session._apply(await api.get('/me') as Map<String, dynamic>, token);
      } catch (_) {
        await session._clear(); // expired token or server unreachable: start logged out
      }
    }
    return session;
  }

  void _apply(Map<String, dynamic> data, String token) {
    api.token = token;
    user = Map<String, dynamic>.from(data['user'] as Map);
    org = data['org'] == null ? null : Map<String, dynamic>.from(data['org'] as Map);
  }

  Future<void> _saveToken() async {
    final prefs = await SharedPreferences.getInstance();
    if (api.token == null) {
      await prefs.remove(_kToken);
    } else {
      await prefs.setString(_kToken, api.token!);
    }
  }

  Future<void> login(String email, String password) async {
    final res = await api.post('/auth/login', {'email': email, 'password': password})
        as Map<String, dynamic>;
    _apply(res, res['token'] as String);
    await _saveToken();
    notifyListeners();
  }

  Future<void> register(String name, String email, String password) async {
    final res = await api.post(
        '/auth/register', {'name': name, 'email': email, 'password': password}) as Map<String, dynamic>;
    _apply(res, res['token'] as String);
    await _saveToken();
    notifyListeners();
  }

  Future<void> _clear() async {
    api.token = null;
    user = null;
    org = null;
    await _saveToken();
  }

  Future<void> logout() async {
    await _clear();
    notifyListeners();
  }

  Future<void> setBaseUrl(String url) async {
    api.baseUrl = url.trim().replaceAll(RegExp(r'/+$'), '');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUrl, api.baseUrl);
  }
}

/// Makes the [Session] available to every widget.
class AppScope extends InheritedNotifier<Session> {
  const AppScope({super.key, required Session session, required super.child})
      : super(notifier: session);

  /// Use in build methods (rebuilds when the session changes).
  static Session of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  /// Use in callbacks (no rebuild dependency).
  static Session read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
