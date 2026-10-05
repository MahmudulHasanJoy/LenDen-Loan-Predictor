import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class ApiException implements Exception {
  final String message;
  final int? status;
  ApiException(this.message, [this.status]);

  bool get unauthorized => status == 401;

  @override
  String toString() => message;
}

/// Thin JSON client for the LenDen API. Adds the bearer token when logged in.
class Api {
  static const _timeout = Duration(seconds: 20);

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
  String? token;
  final http.Client _http;

  Api({required this.baseUrl, this.token, http.Client? client})
      : _http = client ?? http.Client();

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Uri _uri(String path, [Map<String, String>? query]) {
    final uri = Uri.parse('$baseUrl$path');
    return query == null || query.isEmpty ? uri : uri.replace(queryParameters: query);
  }

  Future<dynamic> get(String path, {Map<String, String>? query}) =>
      _send(() => _http.get(_uri(path, query), headers: _headers));

  Future<dynamic> post(String path, [Object? body]) => _send(
      () => _http.post(_uri(path), headers: _headers, body: jsonEncode(body ?? const {})));

  Future<dynamic> put(String path, [Object? body]) => _send(
      () => _http.put(_uri(path), headers: _headers, body: jsonEncode(body ?? const {})));

  Future<dynamic> patch(String path, [Object? body]) => _send(
      () => _http.patch(_uri(path), headers: _headers, body: jsonEncode(body ?? const {})));

  Future<dynamic> _send(Future<http.Response> Function() request) async {
    http.Response res;
    try {
      res = await request().timeout(_timeout);
    } on TimeoutException {
      throw ApiException('The server did not respond. Check the server address.');
    } catch (e) {
      throw ApiException('Could not reach $baseUrl. Is the server running?');
    }
    dynamic body;
    try {
      body = res.body.isEmpty ? null : jsonDecode(utf8.decode(res.bodyBytes));
    } on FormatException {
      body = null;
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return body;
    throw ApiException(_detail(body) ?? 'Error ${res.statusCode}', res.statusCode);
  }

  /// Turns FastAPI / service error payloads into one readable sentence.
  static String? _detail(dynamic body) {
    if (body is! Map) return null;
    final d = body['detail'];
    if (d is String) return d;
    if (d is Map) return d.entries.map((e) => '${e.key}: ${e.value}').join('\n');
    if (d is List) {
      return d
          .map((e) => e is Map ? '${(e['loc'] as List?)?.last ?? ''}: ${e['msg']}' : '$e')
          .join('\n');
    }
    return null;
  }
}
