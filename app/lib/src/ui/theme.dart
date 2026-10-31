import 'package:flutter/material.dart';

const kBg = Color(0xFF0B0D10);
const kSurface = Color(0xFF14171C);
const kSurface2 = Color(0xFF1B2027);
const kBorder = Color(0xFF262C35);
const kAccent = Color(0xFF64E6A3);
const kText = Color(0xFFE6EAF0);
const kMuted = Color(0xFF8B95A3);

ThemeData buildTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  final scheme = base.colorScheme.copyWith(
    primary: kAccent,
    onPrimary: const Color(0xFF06231A),
    secondary: const Color(0xFF7AA7FF),
    surface: kSurface,
    onSurface: kText,
    outline: kBorder,
    error: const Color(0xFFFF7B72),
  );
  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: kBg,
    canvasColor: kBg,
    dividerColor: kBorder,
    appBarTheme: const AppBarTheme(
      backgroundColor: kBg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: kText,
        fontSize: 17,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
      ),
    ),
    textTheme: base.textTheme.apply(bodyColor: kText, displayColor: kText),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: kSurface2,
      hintStyle: const TextStyle(color: kMuted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: kBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: kBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: kAccent, width: 1.4),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: kAccent,
        foregroundColor: const Color(0xFF06231A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: kAccent),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: kSurface2,
      contentTextStyle: TextStyle(color: kText),
      behavior: SnackBarBehavior.floating,
    ),
    dividerTheme: const DividerThemeData(color: kBorder, thickness: 1),
  );
}

const kMono = TextStyle(
  fontFamily: 'monospace',
  fontSize: 12.5,
  height: 1.45,
  color: Color(0xFFCFE3D8),
);
