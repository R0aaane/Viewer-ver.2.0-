import 'package:flutter/material.dart';

import 'database/app_db.dart';
import 'database/tag_service.dart';
import 'repository/mediaRepository.dart';
import 'repository/repositoryFactory.dart';
import 'scene/gridGallery.dart';
import 'services/host_api_server_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('[FlutterError] ${details.exceptionAsString()}');
    if (details.stack != null) {
      debugPrintStack(label: '[FlutterError]', stackTrace: details.stack);
    }
  };
  ErrorWidget.builder = (details) {
    debugPrint('[ErrorWidget] ${details.exceptionAsString()}');
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Material(
        color: const Color(0xFF160F10),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              '画面の描画中にエラーが発生しました。\n${details.exceptionAsString()}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ),
      ),
    );
  };

  final appDb = AppDb();
  final tagService = TagService(appDb);
  await tagService.initialize();
  final hostServerService = HostApiServerService();
  await hostServerService.refresh();

  final repo = createRepository(appDb, initialSettings: tagService.settings);

  runApp(
    MyApp(
      appDb: appDb,
      tagService: tagService,
      repo: repo,
      hostServerService: hostServerService,
    ),
  );
}

class MyApp extends StatelessWidget {
  final AppDb appDb;
  final TagService tagService;
  final MediaRepository repo;
  final HostApiServerService hostServerService;

  const MyApp({
    super.key,
    required this.appDb,
    required this.tagService,
    required this.repo,
    required this.hostServerService,
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
        color: const Color(0xFF141418),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(40, 40),
          padding: const EdgeInsets.all(8),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
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
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
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
      dialogTheme: DialogThemeData(
        backgroundColor: const Color(0xFF16171C),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'メディアビューア',
      theme: _buildTheme(),
      home: GalleryGridPage(
        repo: repo,
        tagService: tagService,
        hostServerService: hostServerService,
      ),
    );
  }
}
