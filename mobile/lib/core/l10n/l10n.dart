import 'package:flutter/widgets.dart';

import '../format.dart' as f;
import 'strings_bn.dart';
import 'strings_en.dart';

/// App strings in English and Bangla. Every user-facing string goes through `context.t('key')`.
/// The API only sends stable codes (reason codes, statuses, error codes); they are translated here.
class L10n {
  static const supported = [Locale('en'), Locale('bn')];
  static const _tables = {'en': stringsEn, 'bn': stringsBn};

  static String lookup(String lang, String key, [Map<String, Object?> args = const {}]) {
    var s = _tables[lang]?[key] ?? stringsEn[key] ?? key;
    if (args.isNotEmpty) {
      args.forEach((k, v) => s = s.replaceAll('{$k}', '${v ?? ''}'));
    }
    return s;
  }

  static bool has(String key) => stringsEn.containsKey(key);
}

extension L10nContext on BuildContext {
  String get lang => Localizations.maybeLocaleOf(this)?.languageCode ?? 'en';

  String t(String key, [Map<String, Object?> args = const {}]) => L10n.lookup(lang, key, args);

  /// Translate a code with a prefix, falling back to [fallback] (e.g. the server's English text).
  String code(String prefix, String? code, {String? fallback}) {
    if (code == null) return fallback ?? '';
    final key = '$prefix.$code';
    return L10n.has(key) ? t(key) : (fallback ?? code);
  }

  String money(num? n, {String currency = 'BDT'}) => f.money(n, currency: currency, lang: lang);
  String pct(num? n, {int digits = 1}) => f.pct(n, digits: digits, lang: lang);
  String num0(num? n, {int digits = 0}) => f.number(n, digits: digits, lang: lang);
  String date(String? iso) => f.shortDate(iso, lang: lang);
  String dateTime(String? iso) => f.dateTime(iso, lang: lang);
  String ago(String? iso) => f.relative(iso, lang: lang);
  String digits(Object v) => f.localDigits('$v', lang);
  String value(String feature, Object? v, {String currency = 'BDT'}) =>
      f.formatValue(feature, v, lang: lang, currency: currency);
  String field(String name) => code('field', name, fallback: name);
}
