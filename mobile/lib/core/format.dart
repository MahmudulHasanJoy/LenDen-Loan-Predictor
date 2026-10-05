import 'package:flutter/material.dart';

String thousands(num n) {
  final neg = n < 0;
  final s = n.abs().round().toString();
  final buf = StringBuffer(neg ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}

String money(num? n) => n == null ? '-' : '\$${thousands(n)}';

String pct(num? n, [int digits = 1]) =>
    n == null ? '-' : '${(n * 100).toStringAsFixed(digits)}%';

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String shortDate(String? iso) {
  if (iso == null) return '-';
  final d = DateTime.tryParse(iso)?.toLocal();
  if (d == null) return iso;
  return '${d.day} ${_months[d.month - 1]} ${d.year}';
}

/// Formats a model input value for display (money, percentages, ratios).
String formatValue(String feature, Object? value) {
  if (value == null) return '-';
  if (value is! num) return value.toString();
  switch (feature) {
    case 'Income':
    case 'LoanAmount':
      return money(value);
    case 'InterestRate':
      return '${value.toStringAsFixed(1)}%';
    case 'DTIRatio':
      return value.toStringAsFixed(2);
    default:
      return value == value.roundToDouble() ? value.round().toString() : value.toStringAsFixed(1);
  }
}

// ---------------------------------------------------------------- readiness lights
class LightStyle {
  final Color color;
  final IconData icon;
  final String label;
  const LightStyle(this.color, this.icon, this.label);
}

const lightStyles = {
  'green': LightStyle(Color(0xFF16A34A), Icons.check_circle, 'Ready'),
  'yellow': LightStyle(Color(0xFFD97706), Icons.error, 'Borderline'),
  'red': LightStyle(Color(0xFFDC2626), Icons.cancel, 'High risk'),
};

LightStyle lightStyle(String? light) => lightStyles[light] ?? lightStyles['yellow']!;

// ---------------------------------------------------------------- application status
class StatusStyle {
  final Color color;
  final String label;
  const StatusStyle(this.color, this.label);
}

const statusStyles = {
  'submitted': StatusStyle(Color(0xFF2563EB), 'Submitted'),
  'needs_docs': StatusStyle(Color(0xFF7C3AED), 'Documents needed'),
  'approved': StatusStyle(Color(0xFF16A34A), 'Approved'),
  'rejected': StatusStyle(Color(0xFFDC2626), 'Not approved'),
};

StatusStyle statusStyle(String? s) =>
    statusStyles[s] ?? const StatusStyle(Colors.grey, 'Unknown');
