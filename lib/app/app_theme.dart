import 'package:flutter/material.dart';

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFFF2B7C8),
    brightness: Brightness.dark,
  );

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: const Color(0xFF100B0E),
  );

  return base.copyWith(
    appBarTheme: const AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      surfaceTintColor: Colors.transparent,
    ),
    dividerTheme: const DividerThemeData(
      thickness: 1,
      space: 1,
      color: Colors.white12,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      color: const Color(0xFF191317),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(40, 40),
        padding: const EdgeInsets.all(8),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      side: const BorderSide(color: Colors.white12),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      showCloseIcon: true,
    ),
    listTileTheme: ListTileThemeData(
      dense: false,
      iconColor: Colors.white70,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: const Color(0xFF191317),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.white12),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.white12),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.primary, width: 1.2),
      ),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: const Color(0xFF191317),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.white12),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: const Color(0xFF1D161A),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
  );
}
