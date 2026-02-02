import 'package:flutter/material.dart';

import 'scene/gridGallery.dart';
import 'repository/folderRepository.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = WindowsFolderRepository();

    return MaterialApp(
      title: 'Media Viewer (Windows)',
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