import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

/// An error from the API. [code] is stable (e.g. `LADDER_LIMIT`) and is what the app translates;
/// [message] is the server's English fallback.
class ApiException implements Exception {
  final String message;
  final int? status;
  final String? code;
  final Map<String, dynamic> fields;

  ApiException(this.message, {this.status, this.code, this.fields = const {}});

  bool get unauthorized => status == 401;
  bool get offline => status == null;

  @override
  String toString() => message;
}

/// JSON client for the LenDen API (/v1). Adds the bearer token, refreshes it when it expires,
/// sends the anonymous draft token and idempotency keys, and uploads files.
class ApiClient {
  static const _timeout = Duration(seconds: 25);

  /// Set at build time: `flutter build apk --dart-define=API_URL=https://your-app.onrender.com`
  static const _buildUrl = String.fromEnvironment('API_URL');

  /// Where the API lives when the user has not chosen a server:
  /// 1. the URL baked in with --dart-define=API_URL,
  /// 2. on a deployed web build, the same site that served the app,
  /// 3. Android emulator -> host computer (10.0.2.2), otherwise localhost.
  static String get platformDefaultUrl {
    if (_buildUrl.isNotEmpty) return _buildUrl;
    if (kIsWeb && kReleaseMode) return Uri.base.origin;
    return !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? 'http://10.0.2.2:8000'
        : 'http://localhost:8000';
  }

  String baseUrl;
  String? accessToken;
  String? refreshToken;
  String? draftToken;

  /// Called after the tokens change (so the session can persist the refresh token).
  void Function(String? refreshToken)? onTokens;

  /// Called when the refresh token is no longer accepted: the user must log in again.
  void Function()? onSessionExpired;

  final http.Client _http;
  Future<bool>? _refreshing;

  ApiClient({required this.baseUrl, http.Client? client}) : _http = client ?? http.Client();

  String url(String path) => '$baseUrl$path';

  Map<String, String> _headers({String? idempotencyKey, bool json = true}) => {
        if (json) 'Content-Type': 'application/json',
        'Accept': 'application/json',
        if (accessToken != null) 'Authorization': 'Bearer $accessToken',
        if (draftToken != null) 'X-Draft-Token': draftToken!,
        if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey,
      };

  Uri _uri(String path, [Map<String, String>? query]) {
    final uri = Uri.parse('$baseUrl/v1$path');
    return query == null || query.isEmpty ? uri : uri.replace(queryParameters: query);
  }

  /// A fresh key for one logical write (keep it when retrying the same action).
  static String newIdempotencyKey() {
    final r = Random.secure();
    return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  Future<dynamic> get(String path, {Map<String, String>? query}) =>
      _send(() => _http.get(_uri(path, query), headers: _headers()));

  Future<dynamic> post(String path, [Object? body, String? idempotencyKey]) => _send(() => _http.post(_uri(path),
      headers: _headers(idempotencyKey: idempotencyKey), body: jsonEncode(body ?? const {})));

  Future<dynamic> put(String path, [Object? body]) =>
      _send(() => _http.put(_uri(path), headers: _headers(), body: jsonEncode(body ?? const {})));

  Future<dynamic> patch(String path, [Object? body]) =>
      _send(() => _http.patch(_uri(path), headers: _headers(), body: jsonEncode(body ?? const {})));

  Future<dynamic> delete(String path) => _send(() => _http.delete(_uri(path), headers: _headers()));

  /// Multipart upload of one file plus form fields.
  Future<dynamic> upload(String path,
      {required Map<String, String> fields,
      required Uint8List bytes,
      required String filename,
      required String contentType}) {
    return _send(() async {
      final req = http.MultipartRequest('POST', _uri(path))
        ..headers.addAll(_headers(json: false))
        ..fields.addAll(fields)
        ..files.add(http.MultipartFile.fromBytes('file', bytes,
            filename: filename, contentType: MediaType.parse(contentType)));
      final streamed = await _http.send(req);
      return http.Response.fromStream(streamed);
    });
  }

  Future<dynamic> _send(Future<http.Response> Function() request, {bool retried = false}) async {
    http.Response res;
    try {
      res = await request().timeout(_timeout);
    } on TimeoutException {
      throw ApiException('The server did not respond. It may be waking up - try again in a moment.');
    } catch (e) {
      throw ApiException('Could not reach $baseUrl. Check your connection or the server address.');
    }
    dynamic body;
    try {
      body = res.body.isEmpty ? null : jsonDecode(utf8.decode(res.bodyBytes));
    } on FormatException {
      body = null;
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return body;
    final err = _error(body, res.statusCode);
    if (res.statusCode == 401 && !retried && err.code == 'TOKEN_EXPIRED' && refreshToken != null) {
      if (await _refresh()) return _send(request, retried: true);
    }
    throw err;
  }

  Future<bool> _refresh() {
    return _refreshing ??= () async {
      try {
        final res = await _http
            .post(_uri('/auth/refresh'), headers: {'Content-Type': 'application/json'},
                body: jsonEncode({'refresh_token': refreshToken}))
            .timeout(_timeout);
        if (res.statusCode != 200) {
          accessToken = null;
          refreshToken = null;
          onTokens?.call(null);
          onSessionExpired?.call();
          return false;
        }
        final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        accessToken = data['access_token'] as String?;
        refreshToken = data['refresh_token'] as String?;
        onTokens?.call(refreshToken);
        return true;
      } catch (_) {
        return false;
      } finally {
        _refreshing = null;
      }
    }();
  }

  static ApiException _error(dynamic body, int status) {
    if (body is! Map) return ApiException('Error $status', status: status);
    final detail = body['detail'];
    final fields = body['fields'] is Map ? Map<String, dynamic>.from(body['fields'] as Map) : <String, dynamic>{};
    String message;
    if (detail is String && detail.isNotEmpty) {
      message = detail;
    } else if (fields.isNotEmpty) {
      message = fields.entries.map((e) => '${e.key}: ${e.value}').join('\n');
    } else {
      message = 'Error $status';
    }
    return ApiException(message, status: status, code: body['code'] as String?, fields: fields);
  }
}
