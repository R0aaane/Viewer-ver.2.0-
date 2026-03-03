import 'package:flutter/material.dart';

import 'scene/gridGallery.dart';
import 'repository/repositoryFactory.dart';

import 'database/app_db.dart';
import 'database/tag_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  final appDb = AppDb();
  final tagService = TagService(appDb);

  runApp(MyApp(appDb: appDb, tagService: tagService));
}

class MyApp extends StatelessWidget {
  final AppDb appDb;
  final TagService tagService;

  const MyApp({
    super.key,
    required this.appDb,
    required this.tagService,
  });

  ThemeData _buildTheme() {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF6AA6FF),
      brightness: Brightness.dark,
    );

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF0B0B0C),
    );

    return base.copyWith(
      appBarTheme: const AppBarTheme(
        elevation: 0,
        centerTitle: false,
        surfaceTintColor: Colors.transparent,
      ),
      dividerTheme: const DividerThemeData(
        thickness: 1,
        space: 1,
        color: Colors.white12,
      ),

      // ✅ CardTheme → CardThemeData
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),

      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        showCloseIcon: true,
      ),
      listTileTheme: const ListTileThemeData(
        dense: false,
        iconColor: Colors.white70,
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: const Color(0xFF141418),
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
          fillColor: const Color(0xFF141418),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Colors.white12),
          ),
        ),
      ),

      // ✅ DialogTheme → DialogThemeData
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // ✅ createRepository に AppDb を渡す
    final repo = createRepository(appDb);

    return MaterialApp(
      title: 'Media Viewer',
      theme: _buildTheme(),
      home: GalleryGridPage(repo: repo, tagService: tagService),
    );
  }
}