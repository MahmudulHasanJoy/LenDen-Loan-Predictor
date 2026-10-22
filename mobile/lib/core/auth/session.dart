import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';

/// Overridden in main() with the instance loaded at start-up.
final prefsProvider = Provider<SharedPreferences>((ref) => throw UnimplementedError('prefsProvider'));

/// The one API client for the app.
final apiProvider = Provider<ApiClient>((ref) {
  final prefs = ref.watch(prefsProvider);
  return ApiClient(baseUrl: prefs.getString(Keys.server) ?? ApiClient.platformDefaultUrl);
});

class Keys {
  static const server = 'api_base_url';
  static const refresh = 'refresh_token';
  static const locale = 'locale';
  static const draftId = 'draft_id';
  static const draftToken = 'draft_token';
  static const onboarded = 'onboarded';
}

typedef Json = Map<String, dynamic>;

/// Who is logged in.
@immutable
class SessionState {
  final Json? user;
  final Json? org;
  final List<Json> levels;
  final int unread;

  const SessionState({this.user, this.org, this.levels = const [], this.unread = 0});

  static const empty = SessionState();

  bool get loggedIn => user != null;
  String? get role => user?['role'] as String?;
  bool get isBorrower => role == 'borrower';
  bool get isStaff => role == 'officer' || role == 'admin';
  bool get isAdmin => role == 'admin';
  bool get isOwner => role == 'superadmin';
  String get name => (user?['name'] as String?) ?? '';
  String get email => (user?['email'] as String?) ?? '';
  String get orgName => (org?['name'] as String?) ?? '';
  String get currency => (org?['currency'] as String?) ?? 'BDT';
  int? get userId => user?['id'] as int?;

  String get homePath => switch (role) {
        'borrower' => '/home',
        'officer' || 'admin' => '/staff',
        'superadmin' => '/platform',
        _ => '/',
      };

  SessionState copyWith({Json? user, Json? org, List<Json>? levels, int? unread}) => SessionState(
      user: user ?? this.user, org: org ?? this.org, levels: levels ?? this.levels, unread: unread ?? this.unread);
}

class SessionController extends Notifier<SessionState> {
  late ApiClient _api;
  late SharedPreferences _prefs;

  @override
  SessionState build() {
    _api = ref.watch(apiProvider);
    _prefs = ref.watch(prefsProvider);
    _api.onTokens = (rt) {
      if (rt == null) {
        _prefs.remove(Keys.refresh);
      } else {
        _prefs.setString(Keys.refresh, rt);
      }
    };
    _api.onSessionExpired = () => state = SessionState.empty;
    _api.draftToken = _prefs.getString(Keys.draftToken);
    return SessionState.empty;
  }

  /// At start-up: turn a saved refresh token into a session (or start logged out).
  Future<void> restore() async {
    final rt = _prefs.getString(Keys.refresh);
    if (rt == null) return;
    _api.refreshToken = rt;
    try {
      final res = await _api.post('/auth/refresh', {'refresh_token': rt}) as Json;
      await _apply(res);
    } catch (_) {
      await _clearTokens();
    }
  }

  Future<void> _apply(Json res) async {
    _api.accessToken = res['access_token'] as String? ?? res['token'] as String?;
    _api.refreshToken = res['refresh_token'] as String?;
    if (_api.refreshToken != null) await _prefs.setString(Keys.refresh, _api.refreshToken!);
    state = SessionState(user: Map<String, dynamic>.from(res['user'] as Map),
        org: res['org'] == null ? null : Map<String, dynamic>.from(res['org'] as Map));
    // A draft started before logging in now belongs to this account.
    if (state.isBorrower) {
      _api.draftToken = null;
      await _prefs.remove(Keys.draftToken);
    }
    await refreshMe();
  }

  Future<void> refreshMe() async {
    if (!state.loggedIn) return;
    try {
      final me = await _api.get('/me') as Json;
      state = state.copyWith(
        user: Map<String, dynamic>.from(me['user'] as Map),
        org: me['org'] == null ? null : Map<String, dynamic>.from(me['org'] as Map),
        levels: (me['levels'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList(),
        unread: (me['unread_notifications'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      // keep what we have; screens show their own errors
    }
  }

  String? get _anonToken => _prefs.getString(Keys.draftToken);

  Future<void> login(String email, String password, {String? totp}) async {
    final res = await _api.post('/auth/login', {
      'email': email.trim(),
      'password': password,
      if (totp != null && totp.isNotEmpty) 'totp': totp,
      if (_anonToken != null) 'anon_token': _anonToken,
    }) as Json;
    await _apply(res);
  }

  Future<void> register(String name, String email, String password, {String? phone, required String locale}) async {
    final res = await _api.post('/auth/register', {
      'name': name.trim(),
      'email': email.trim(),
      'password': password,
      if (phone != null && phone.trim().isNotEmpty) 'phone': phone.trim(),
      'locale': locale,
      if (_anonToken != null) 'anon_token': _anonToken,
    }) as Json;
    await _apply(res);
  }

  Future<Json> requestOtp(String phone) async => await _api.post('/auth/otp/request', {'phone': phone}) as Json;

  Future<void> loginWithOtp(String phone, String code) async {
    final res = await _api.post('/auth/otp/verify', {
      'phone': phone,
      'code': code,
      if (_anonToken != null) 'anon_token': _anonToken,
    }) as Json;
    await _apply(res);
  }

  /// After changing the password the server ends other sessions and returns a new one.
  Future<void> adopt(Json res) => _apply(res);

  void setUnread(int n) => state = state.copyWith(unread: n);

  Future<void> logout() async {
    final rt = _api.refreshToken;
    if (rt != null) {
      try {
        await _api.post('/auth/logout', {'refresh_token': rt});
      } catch (_) {}
    }
    await _clearTokens();
    state = SessionState.empty;
  }

  Future<void> _clearTokens() async {
    _api.accessToken = null;
    _api.refreshToken = null;
    await _prefs.remove(Keys.refresh);
  }

  Future<void> setServer(String url) async {
    _api.baseUrl = url.trim().replaceAll(RegExp(r'/+$'), '');
    await _prefs.setString(Keys.server, _api.baseUrl);
  }
}

final sessionProvider = NotifierProvider<SessionController, SessionState>(SessionController.new);

/// The app language, saved on the device (and on the account when logged in).
class LocaleController extends Notifier<Locale> {
  @override
  Locale build() => Locale(ref.watch(prefsProvider).getString(Keys.locale) ?? 'en');

  Future<void> set(String code) async {
    state = Locale(code);
    await ref.read(prefsProvider).setString(Keys.locale, code);
    if (ref.read(sessionProvider).loggedIn) {
      try {
        await ref.read(apiProvider).put('/me', {'locale': code});
      } catch (_) {}
    }
  }
}

final localeProvider = NotifierProvider<LocaleController, Locale>(LocaleController.new);
