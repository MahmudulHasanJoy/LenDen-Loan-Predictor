import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Brand and semantic colour tokens. Use these instead of ad-hoc colours.
class Brand {
  static const primary = Color(0xFF0F766E);      // deep teal
  static const primaryDark = Color(0xFF115E59);
  static const accent = Color(0xFF14B8A6);
  static const ink = Color(0xFF0F172A);          // headings
  static const muted = Color(0xFF64748B);        // secondary text
  static const canvas = Color(0xFFF6F7F9);       // page background
  static const border = Color(0xFFE5E7EB);

  static const success = Color(0xFF16A34A);
  static const warning = Color(0xFFD97706);
  static const danger = Color(0xFFDC2626);
  static const info = Color(0xFF2563EB);

  static const canvasDark = Color(0xFF0B1220);
  static const surfaceDark = Color(0xFF111827);
  static const borderDark = Color(0xFF1F2937);

  static const heroGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF0F766E), Color(0xFF134E4A), Color(0xFF0F172A)],
  );
}

/// Spacing and radius scale (4-point grid).
class Space {
  static const xs = 4.0, sm = 8.0, md = 12.0, lg = 16.0, xl = 24.0, xxl = 32.0;
  static const radius = 14.0;
  static const radiusLg = 20.0;
}

class AppTheme {
  /// [googleFonts] is false in widget tests, which have no network to download Inter.
  static ThemeData light({bool googleFonts = true}) => _build(Brightness.light, googleFonts);
  static ThemeData dark({bool googleFonts = true}) => _build(Brightness.dark, googleFonts);

  static ThemeData _build(Brightness b, bool googleFonts) {
    final dark = b == Brightness.dark;
    final scheme = ColorScheme.fromSeed(seedColor: Brand.primary, brightness: b).copyWith(
      primary: dark ? Brand.accent : Brand.primary,
      surface: dark ? Brand.surfaceDark : Colors.white,
      surfaceContainerLowest: dark ? Brand.canvasDark : Brand.canvas,
      outlineVariant: dark ? Brand.borderDark : Brand.border,
      error: Brand.danger,
    );
    final canvas = dark ? Brand.canvasDark : Brand.canvas;
    final border = dark ? Brand.borderDark : Brand.border;
    final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: b);
    final text = (googleFonts ? GoogleFonts.interTextTheme(base.textTheme) : base.textTheme).apply(
      bodyColor: dark ? const Color(0xFFE5E7EB) : Brand.ink,
      displayColor: dark ? Colors.white : Brand.ink,
    );
    final rounded = RoundedRectangleBorder(borderRadius: BorderRadius.circular(Space.radius));

    return base.copyWith(
      scaffoldBackgroundColor: canvas,
      textTheme: text.copyWith(
        headlineMedium: text.headlineMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.5),
        headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3),
        titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        bodySmall: text.bodySmall?.copyWith(color: dark ? const Color(0xFF94A3B8) : Brand.muted),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: canvas,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      ),
      cardTheme: CardThemeData(
        color: scheme.surface,
        elevation: 0,
        margin: const EdgeInsets.symmetric(vertical: Space.xs + 2),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Space.radius),
          side: BorderSide(color: border),
        ),
      ),
      dividerTheme: DividerThemeData(color: border, space: 1, thickness: 1),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surface,
        contentPadding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: 14),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: border)),
        enabledBorder:
            OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: border)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: scheme.primary, width: 1.6)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 48),
          shape: rounded,
          textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600, fontSize: 15),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 48),
          shape: rounded,
          side: BorderSide(color: border),
          textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          side: BorderSide(color: border),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        side: BorderSide(color: border),
      ),
      listTileTheme: ListTileThemeData(shape: rounded),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 68,
        indicatorColor: scheme.primary.withValues(alpha: 0.12),
        labelTextStyle: WidgetStatePropertyAll(text.labelSmall?.copyWith(fontWeight: FontWeight.w600)),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.primary.withValues(alpha: 0.12),
        selectedIconTheme: IconThemeData(color: scheme.primary),
        selectedLabelTextStyle:
            text.labelLarge?.copyWith(color: scheme.primary, fontWeight: FontWeight.w600),
        unselectedLabelTextStyle: text.labelLarge,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Space.radiusLg)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(Space.radiusLg))),
      ),
    );
  }
}
