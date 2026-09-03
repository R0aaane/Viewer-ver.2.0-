import 'package:flutter/material.dart';

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFFF09AAF),
    brightness: Brightness.dark,
    surface: const Color(0xFF17181C),
  );

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: const Color(0xFF111214),
  );

  return base.copyWith(
    appBarTheme: const AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      surfaceTintColor: Colors.transparent,
      backgroundColor: Color(0xFF111214),
      titleTextStyle: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
    ),
    dividerTheme: const DividerThemeData(
      thickness: 1,
      space: 1,
      color: Color(0xFF2B2D33),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      color: const Color(0xFF1A1B20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        foregroundColor: const Color(0xFFE8E8EA),
        side: const BorderSide(color: Color(0xFF35373E)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(36, 36),
        padding: const EdgeInsets.all(8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      labelStyle: const TextStyle(fontSize: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      side: const BorderSide(color: Color(0xFF35373E)),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      showCloseIcon: true,
    ),
    listTileTheme: ListTileThemeData(
      dense: true,
      iconColor: const Color(0xFFB7B9C0),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      minLeadingWidth: 28,
      selectedColor: const Color(0xFFF5B3C1),
      selectedTileColor: const Color(0xFF332329),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: const Color(0xFF1A1B20),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0xFF35373E)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0xFF35373E)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: scheme.primary, width: 1.2),
      ),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: const Color(0xFF1A1B20),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF35373E)),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: const Color(0xFF1E2026),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    textTheme: base.textTheme.copyWith(
      titleLarge: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
      titleMedium: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      titleSmall: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
      bodyMedium: const TextStyle(fontSize: 14, height: 1.4),
      bodySmall: const TextStyle(fontSize: 12, height: 1.35),
      labelLarge: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      labelMedium: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
    ),
  );
}
