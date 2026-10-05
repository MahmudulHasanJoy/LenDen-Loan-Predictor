import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lenden/core/api.dart';
import 'package:lenden/core/format.dart';
import 'package:lenden/core/session.dart';
import 'package:lenden/core/theme.dart';
import 'package:lenden/models/field_spec.dart';
import 'package:lenden/screens/borrower/emi_screen.dart';
import 'package:lenden/screens/borrower/readiness_screen.dart';

const _readiness = <String, dynamic>{
  'light': 'red',
  'title': 'High risk: wait or change the loan',
  'message': 'Lenders are likely to hesitate.',
  'default_probability': 0.2286,
  'tips': [
    {
      'feature': 'LoanAmount',
      'change': {'LoanAmount': 60000.0},
      'text': 'Borrow 60,000 instead of 120,000',
      'new_probability': 0.2018,
      'new_light': 'red',
      'points_lower': 2.7,
    },
    {
      'feature': 'HasCoSigner',
      'change': {'HasCoSigner': 'Yes'},
      'text': 'Apply with a co-signer',
      'new_probability': 0.2018,
      'new_light': 'red',
      'points_lower': 2.7,
    },
  ],
  'plan': {
    'steps': ['Borrow 60,000 instead of 120,000', 'Apply with a co-signer'],
    'new_probability': 0.1258,
    'new_light': 'yellow',
    'points_lower': 10.3,
  },
  'affordability': {
    'monthly_payment': 3079.95,
    'total_repayment': 184796.71,
    'total_interest': 64796.71,
    'income_share': 0.8213,
    'level': 'risky',
    'note': 'The instalment takes more than 40% of your income.',
  },
};

Widget _wrap(Widget child) => AppScope(
      session: Session(Api(baseUrl: 'http://localhost:8000')),
      child: MaterialApp(theme: AppTheme.light(googleFonts: false), home: child),
    );

void main() {
  test('formatters', () {
    expect(money(45000), '\$45,000');
    expect(money(1250000), '\$1,250,000');
    expect(pct(0.1378), '13.8%');
    expect(formatValue('InterestRate', 14.5), '14.5%');
    expect(formatValue('DTIRatio', 0.4), '0.40');
    expect(formatValue('Education', 'PhD'), 'PhD');
    expect(shortDate('2026-10-05T09:00:00+00:00'), contains('2026'));
  });

  test('EMI matches the API formula', () {
    expect(emi(100000, 12, 12).toStringAsFixed(2), '8884.88');
    expect(emi(1200, 0, 12), 100);
  });

  test('FieldSpec parses integer options and categories', () {
    final term = FieldSpec.fromJson({
      'name': 'LoanTerm',
      'label': 'Loan term (months)',
      'type': 'integer',
      'min': 12.0,
      'max': 60.0,
      'options': [12, 24, 36, 48, 60],
      'default': 36.0,
    });
    expect(term.options, [12, 24, 36, 48, 60]);
    expect(term.defaultValue, 36);
  });

  testWidgets('Readiness result shows light, tips, plan and affordability', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_wrap(ReadinessScreen(
      inputs: const {'LoanAmount': 120000},
      result: _readiness,
    )));
    await tester.pump();
    expect(find.byKey(const Key('light-title')), findsOneWidget);
    expect(find.text('Apply with a co-signer'), findsWidgets);
    expect(find.text('Best combined plan'), findsOneWidget);
    expect(find.textContaining('per month'), findsOneWidget);
    expect(find.byKey(const Key('apply')), findsOneWidget);
  });

  testWidgets('EMI screen updates the monthly payment', (tester) async {
    await tester.pumpWidget(_wrap(const EmiScreen()));
    await tester.pump();
    expect(find.byKey(const Key('emi-value')), findsOneWidget);
  });
}
