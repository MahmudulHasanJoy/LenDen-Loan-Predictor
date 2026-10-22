import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lenden/core/auth/session.dart';
import 'package:lenden/core/format.dart';
import 'package:lenden/core/l10n/l10n.dart';
import 'package:lenden/core/theme/theme.dart';
import 'package:lenden/features/borrower/borrower_shell.dart';
import 'package:lenden/features/onboarding/welcome_screen.dart';
import 'package:lenden/shared/models/metadata.dart';
import 'package:lenden/shared/widgets/explain.dart';
import 'package:lenden/shared/widgets/odds.dart';

Future<Widget> _wrap(Widget child, {String locale = 'en'}) async {
  SharedPreferences.setMockInitialValues({Keys.locale: locale});
  final prefs = await SharedPreferences.getInstance();
  return ProviderScope(
    overrides: [prefsProvider.overrideWithValue(prefs)],
    child: Consumer(builder: (context, ref, _) {
      return MaterialApp(
        theme: AppTheme.light(googleFonts: false),
        locale: ref.watch(localeProvider),
        supportedLocales: L10n.supported,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: child,
      );
    }),
  );
}

void main() {
  test('money uses Taka and South Asian grouping', () {
    expect(money(120000), '৳1,20,000');
    expect(money(1250000, currency: 'USD'), '\$1,250,000');
    expect(money(45000, lang: 'bn'), '৳৪৫,০০০');
    expect(pct(0.1378), '13.8%');
  });

  test('strings exist in both languages and fall back to English', () {
    expect(L10n.lookup('bn', 'odds.good'), 'ভালো');
    expect(L10n.lookup('en', 'common.months', {'n': 12}), '12 months');
    expect(L10n.lookup('xx', 'odds.low'), 'Low');
    expect(L10n.lookup('en', 'no.such.key'), 'no.such.key');
  });

  test('field spec snaps integer defaults to an allowed option', () {
    final f = FieldSpec.fromJson({'name': 'LoanTerm', 'type': 'integer', 'min': 12, 'max': 60,
      'options': [12, 24, 36, 48, 60], 'default': 37.4});
    expect(f.defaultValue, 36);
  });

  test('navigation index picks the longest matching path', () {
    const items = [NavItem('/staff', 'q', Icons.inbox, Icons.inbox), NavItem('/staff/dashboard', 'd', Icons.insights, Icons.insights)];
    expect(navIndex(items, '/staff/applications/3'), 0);
    expect(navIndex(items, '/staff/dashboard'), 1);
  });

  testWidgets('welcome screen speaks English and Bangla', (tester) async {
    await tester.pumpWidget(await _wrap(const WelcomeScreen()));
    expect(find.text('Check my chances'), findsOneWidget);
    await tester.tap(find.text('বাংলা'));
    await tester.pumpAndSettle();
    expect(find.text('আমার সম্ভাবনা দেখুন'), findsOneWidget);
  });

  testWidgets('odds hero and next step card render codes as words', (tester) async {
    await tester.pumpWidget(await _wrap(Scaffold(
      body: ListView(children: const [
        OddsHero(odds: 'fair'),
        NextStepCard(step: {
          'odds': 'good',
          'changes': [
            {'feature': 'HasCoSigner', 'code': 'ADD_COSIGNER', 'from': 'No', 'to': 'Yes'}
          ],
        }),
      ]),
    )));
    expect(find.text('Fair'), findsOneWidget);
    expect(find.text('Apply with a co-signer'), findsOneWidget);
    expect(find.text('Good'), findsOneWidget);
  });
}
