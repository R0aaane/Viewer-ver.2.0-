import 'package:flutter/material.dart';

import 'scene/gridGallery.dart';
import 'repository/repositoryFactory.dart'; // ★追加

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = createRepository(); // ★WindowsFolderRepository() をやめる

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
      home: GalleryGridPage(repo: repo),
    );
  }
}
