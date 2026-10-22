import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/auth/session.dart';
import '../core/l10n/l10n.dart';
import '../core/theme/theme.dart';
import 'router.dart';

class LenDenApp extends ConsumerWidget {
  /// False in widget tests, which have no network to download the Inter font.
  final bool googleFonts;
  const LenDenApp({super.key, this.googleFonts = true});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final locale = ref.watch(localeProvider);
    return MaterialApp.router(
      title: 'LenDen',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(googleFonts: googleFonts, bangla: locale.languageCode == 'bn'),
      darkTheme: AppTheme.dark(googleFonts: googleFonts, bangla: locale.languageCode == 'bn'),
      locale: locale,
      supportedLocales: L10n.supported,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      routerConfig: router,
    );
  }
}
