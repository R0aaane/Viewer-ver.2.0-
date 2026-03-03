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

  const MyApp({super.key, required this.appDb, required this.tagService});

  @override
  Widget build(BuildContext context) {
    final repo = createRepository(appDb);

    return MaterialApp(
      title: 'Media Viewer',
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.black,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
        ),
      ),
      home: GalleryGridPage(repo: repo, tagService: tagService),
    );
  }
}
