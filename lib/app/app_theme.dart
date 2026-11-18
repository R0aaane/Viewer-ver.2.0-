import 'package:flutter/material.dart';

ThemeData buildAppTheme({String? fontFamily}) {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xFF8B9DFF),
        brightness: Brightness.dark,
      ).copyWith(
        primary: const Color(0xFF8B9DFF),
        onPrimary: const Color(0xFF182044),
        surface: const Color(0xFF191C23),
        surfaceContainerLow: const Color(0xFF191C23),
        surfaceContainer: const Color(0xFF232730),
        surfaceContainerHigh: const Color(0xFF292E39),
        surfaceContainerHighest: const Color(0xFF303542),
        onSurface: const Color(0xFFF3F4F7),
        onSurfaceVariant: const Color(0xFFA5ACBA),
        outline: const Color(0xFF535B6D),
        outlineVariant: const Color(0xFF303542),
      );

  final base = ThemeData(
    useMaterial3: true,
    fontFamily: fontFamily,
    colorScheme: scheme,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: const Color(0xFF111318),
  );
  final textTheme = base.textTheme.apply(
    bodyColor: scheme.onSurface,
    displayColor: scheme.onSurface,
  );

  return base.copyWith(
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      surfaceTintColor: Colors.transparent,
      backgroundColor: const Color(0xFF111318),
      titleTextStyle: TextStyle(
        fontFamily: fontFamily,
        color: const Color(0xFFF3F4F7),
        fontSize: 20,
        fontWeight: FontWeight.w600,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surface,
      indicatorColor: scheme.primaryContainer,
      height: 72,
    ),
    drawerTheme: DrawerThemeData(backgroundColor: scheme.surface, elevation: 0),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 500),
    ),
    dividerTheme: const DividerThemeData(
      thickness: 1,
      space: 1,
      color: Color(0xFF303542),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      color: const Color(0xFF232730),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        foregroundColor: scheme.onPrimary,
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        foregroundColor: const Color(0xFFF3F4F7),
        side: const BorderSide(color: Color(0xFF303542)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.all(8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      labelStyle: TextStyle(
        fontFamily: fontFamily,
        fontSize: 12,
        color: const Color(0xFFF3F4F7),
      ),
      secondaryLabelStyle: TextStyle(
        fontFamily: fontFamily,
        fontSize: 12,
        color: const Color(0xFFF3F4F7),
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      side: const BorderSide(color: Color(0xFF303542)),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      showCloseIcon: true,
    ),
    listTileTheme: ListTileThemeData(
      dense: false,
      iconColor: const Color(0xFFA5ACBA),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      minLeadingWidth: 28,
      selectedColor: const Color(0xFFB7C2FF),
      selectedTileColor: const Color(0xFF2B3355),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: const Color(0xFF232730),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      labelStyle: TextStyle(
        fontFamily: fontFamily,
        color: const Color(0xFFC7CBD6),
      ),
      hintStyle: TextStyle(
        fontFamily: fontFamily,
        color: const Color(0xFFA5ACBA),
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0xFF303542)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0xFF303542)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: scheme.primary, width: 1.2),
      ),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      textStyle: TextStyle(
        fontFamily: fontFamily,
        color: const Color(0xFFF3F4F7),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: const Color(0xFF232730),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF303542)),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: const Color(0xFF232730),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    textTheme: textTheme.copyWith(
      titleLarge: textTheme.titleLarge?.copyWith(
        fontSize: 24,
        fontWeight: FontWeight.w600,
      ),
      titleMedium: textTheme.titleMedium?.copyWith(
        fontSize: 17,
        fontWeight: FontWeight.w600,
      ),
      titleSmall: textTheme.titleSmall?.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w500,
      ),
      bodyMedium: textTheme.bodyMedium?.copyWith(fontSize: 14, height: 1.4),
      bodySmall: textTheme.bodySmall?.copyWith(fontSize: 12, height: 1.35),
      labelLarge: textTheme.labelLarge?.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
      labelMedium: textTheme.labelMedium?.copyWith(
        fontSize: 11,
        fontWeight: FontWeight.w500,
      ),
    ),
  );
}
