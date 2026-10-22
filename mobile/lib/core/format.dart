import 'package:flutter/material.dart';

const _bnDigits = ['০', '১', '২', '৩', '৪', '৫', '৬', '৭', '৮', '৯'];

/// Bangla digits when the app is in Bangla.
String localDigits(String s, String lang) {
  if (lang != 'bn') return s;
  final b = StringBuffer();
  for (final ch in s.split('')) {
    final d = int.tryParse(ch);
    b.write(d == null ? ch : _bnDigits[d]);
  }
  return b.toString();
}

/// 1,234,567 (international) or 12,34,567 (South Asian grouping, used for Taka).
String groupDigits(num n, {bool lakh = false}) {
  final neg = n < 0;
  final s = n.abs().round().toString();
  String out;
  if (!lakh || s.length <= 3) {
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    out = buf.toString();
  } else {
    final last3 = s.substring(s.length - 3);
    var rest = s.substring(0, s.length - 3);
    final parts = <String>[];
    while (rest.length > 2) {
      parts.insert(0, rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) parts.insert(0, rest);
    out = '${parts.join(',')},$last3';
  }
  return neg ? '-$out' : out;
}

const currencySymbols = {'BDT': '৳', 'USD': '\$', 'EUR': '€', 'INR': '₹', 'GBP': '£'};

String money(num? n, {String currency = 'BDT', String lang = 'en'}) {
  if (n == null) return '-';
  final sym = currencySymbols[currency] ?? '$currency ';
  return localDigits('$sym${groupDigits(n, lakh: currency == 'BDT' || currency == 'INR')}', lang);
}

String pct(num? n, {int digits = 1, String lang = 'en'}) =>
    n == null ? '-' : localDigits('${(n * 100).toStringAsFixed(digits)}%', lang);

String number(num? n, {int digits = 0, String lang = 'en'}) {
  if (n == null) return '-';
  final s = digits == 0 ? groupDigits(n) : n.toStringAsFixed(digits);
  return localDigits(s, lang);
}

const _monthsEn = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _monthsBn = ['জানু', 'ফেব্রু', 'মার্চ', 'এপ্রিল', 'মে', 'জুন', 'জুলাই', 'আগস্ট', 'সেপ্টে', 'অক্টো', 'নভে', 'ডিসে'];

String shortDate(String? iso, {String lang = 'en'}) {
  if (iso == null) return '-';
  final d = DateTime.tryParse(iso)?.toLocal();
  if (d == null) return iso;
  final m = (lang == 'bn' ? _monthsBn : _monthsEn)[d.month - 1];
  return localDigits('${d.day} $m ${d.year}', lang);
}

String dateTime(String? iso, {String lang = 'en'}) {
  if (iso == null) return '-';
  final d = DateTime.tryParse(iso)?.toLocal();
  if (d == null) return iso;
  final hh = d.hour.toString().padLeft(2, '0');
  final mm = d.minute.toString().padLeft(2, '0');
  return '${shortDate(iso, lang: lang)}, ${localDigits('$hh:$mm', lang)}';
}

/// "3h ago", "in 2d" (compact, for queues and inboxes).
String relative(String? iso, {String lang = 'en'}) {
  if (iso == null) return '-';
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  final diff = d.difference(DateTime.now().toUtc());
  final future = !diff.isNegative;
  final a = diff.abs();
  final bn = lang == 'bn';
  String v;
  if (a.inMinutes < 1) return bn ? 'এইমাত্র' : 'just now';
  if (a.inHours < 1) {
    v = '${a.inMinutes}${bn ? ' মিনিট' : 'm'}';
  } else if (a.inDays < 1) {
    v = '${a.inHours}${bn ? ' ঘণ্টা' : 'h'}';
  } else {
    v = '${a.inDays}${bn ? ' দিন' : 'd'}';
  }
  v = localDigits(v, lang);
  if (bn) return future ? '$v পরে' : '$v আগে';
  return future ? 'in $v' : '$v ago';
}

/// Formats a model input value for display (money, percentages, ratios).
String formatValue(String feature, Object? value, {String lang = 'en', String currency = 'BDT'}) {
  if (value == null) return '-';
  if (value is! num) return value.toString();
  switch (feature) {
    case 'Income':
    case 'LoanAmount':
      return money(value, currency: currency, lang: lang);
    case 'InterestRate':
      return localDigits('${value.toStringAsFixed(1)}%', lang);
    case 'DTIRatio':
      return localDigits(value.toStringAsFixed(2), lang);
    default:
      return localDigits(value == value.roundToDouble() ? value.round().toString() : value.toStringAsFixed(1), lang);
  }
}

// ---------------------------------------------------------------- colours for states
const oddsColors = {
  'excellent': Color(0xFF15803D),
  'good': Color(0xFF16A34A),
  'fair': Color(0xFFD97706),
  'low': Color(0xFFDC2626),
};

const oddsIcons = {
  'excellent': Icons.verified_rounded,
  'good': Icons.thumb_up_alt_rounded,
  'fair': Icons.balance_rounded,
  'low': Icons.trending_down_rounded,
};

const lightColors = {'green': Color(0xFF16A34A), 'yellow': Color(0xFFD97706), 'red': Color(0xFFDC2626)};

const statusColors = {
  'submitted': Color(0xFF2563EB),
  'in_review': Color(0xFF0891B2),
  'needs_docs': Color(0xFF7C3AED),
  'approved': Color(0xFF16A34A),
  'rejected': Color(0xFFDC2626),
  'withdrawn': Color(0xFF64748B),
  'active': Color(0xFF0F766E),
  'closed': Color(0xFF16A34A),
  'due': Color(0xFF2563EB),
  'paid': Color(0xFF16A34A),
  'late': Color(0xFFD97706),
  'missed': Color(0xFFDC2626),
  'candidate': Color(0xFF64748B),
  'shadow': Color(0xFF7C3AED),
  'retired': Color(0xFF94A3B8),
  'open': Color(0xFF7C3AED),
  'fulfilled': Color(0xFF16A34A),
  'expired': Color(0xFF94A3B8),
  'cancelled': Color(0xFF94A3B8),
};
