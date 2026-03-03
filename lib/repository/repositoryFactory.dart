import 'dart:io' show Platform;

import 'mediaRepository.dart';
import 'folderRepository.dart';
import 'androidFolderRepository.dart';
import '../database/app_db.dart'; 


MediaRepository createRepository(AppDb db) {
  if (Platform.isAndroid) return AndroidFolderRepository(db);
  return WindowsFolderRepository();
}
