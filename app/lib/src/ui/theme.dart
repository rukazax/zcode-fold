import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// Palettes. Dark keeps the original look 1:1; light is the same design in
// light tones. Colors are resolved through `Pal` at build time so widgets can
// follow the system theme without threading BuildContext everywhere.
// ---------------------------------------------------------------------------

class Palette {
  const Palette({
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.border,
    required this.accent,
    required this.text,
    required this.muted,
    required this.mono,
    required this.codeBg,
    required this.codeText,
  });

  final Color bg;
  final Color surface;
  final Color surface2;
  final Color border;
  final Color accent;
  final Color text;
  final Color muted;
  final Color mono;
  final Color codeBg;
  final Color codeText;
}

const darkPalette = Palette(
  bg: Color(0xFF0B0D10),
  surface: Color(0xFF14171C),
  surface2: Color(0xFF1B2027),
  border: Color(0xFF262C35),
  accent: Color(0xFF64E6A3),
  text: Color(0xFFE6EAF0),
  muted: Color(0xFF8B95A3),
  mono: Color(0xFFCFE3D8),
  codeBg: Color(0xFF0F1418),
  codeText: Color(0xFFCFE3D8),
);

const lightPalette = Palette(
  bg: Color(0xFFF4F6F8),
  surface: Color(0xFFFFFFFF),
  surface2: Color(0xFFEDF1F5),
  border: Color(0xFFD8DEE6),
  accent: Color(0xFF109A63),
  text: Color(0xFF141A21),
  muted: Color(0xFF5D6774),
  mono: Color(0xFF1F3B2F),
  codeBg: Color(0xFFF3F6F4),
  codeText: Color(0xFF1F3B2F),
);

/// Current palette, updated by the app before each frame from the resolved
/// theme brightness. Keeps the existing concise `Pal.bg` call sites.
class Pal {
  Pal._();

  static Palette current = darkPalette;

  static void apply(Brightness brightness) {
    current = brightness == Brightness.dark ? darkPalette : lightPalette;
  }

  static Color get bg => current.bg;
  static Color get surface => current.surface;
  static Color get surface2 => current.surface2;
  static Color get border => current.border;
  static Color get accent => current.accent;
  static Color get text => current.text;
  static Color get muted => current.muted;
  static Color get mono => current.mono;
  static Color get codeBg => current.codeBg;
  static Color get codeText => current.codeText;
}

ThemeData buildTheme(Brightness brightness) {
  final palette = brightness == Brightness.dark ? darkPalette : lightPalette;
  Pal.current = palette;
  final base = ThemeData(
    brightness: brightness,
    useMaterial3: true,
  );
  final scheme = base.colorScheme.copyWith(
    primary: palette.accent,
    onPrimary: brightness == Brightness.dark
        ? const Color(0xFF06231A)
        : Colors.white,
    secondary: brightness == Brightness.dark
        ? const Color(0xFF7AA7FF)
        : const Color(0xFF2F6FE0),
    surface: palette.surface,
    onSurface: palette.text,
    outline: palette.border,
    error: brightness == Brightness.dark
        ? const Color(0xFFFF7B72)
        : const Color(0xFFC6291F),
  );
  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: palette.bg,
    canvasColor: palette.bg,
    dividerColor: palette.border,
    appBarTheme: AppBarTheme(
      backgroundColor: palette.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: palette.text,
        fontSize: 17,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
      ),
    ),
    textTheme: base.textTheme.apply(bodyColor: palette.text, displayColor: palette.text),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.surface2,
      hintStyle: TextStyle(color: palette.muted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: palette.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: palette.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: palette.accent, width: 1.4),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: palette.accent,
        foregroundColor: brightness == Brightness.dark
            ? const Color(0xFF06231A)
            : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: palette.accent),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: palette.surface2,
      contentTextStyle: TextStyle(color: palette.text),
      behavior: SnackBarBehavior.floating,
    ),
    dividerTheme: DividerThemeData(color: palette.border, thickness: 1),
  );
}

/// Monospace style for code blocks and tool output, theme-aware.
TextStyle get monoStyle => TextStyle(
      fontFamily: 'monospace',
      fontSize: 12.5,
      height: 1.45,
      color: Pal.codeText,
    );
