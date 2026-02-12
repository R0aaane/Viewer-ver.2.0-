import 'dart:io' show Platform;

import 'mediaRepository.dart';
import 'folderRepository.dart';
import 'androidFolderRepository.dart';

MediaRepository createRepository() {
  if (Platform.isAndroid) return AndroidFolderRepository();
  return WindowsFolderRepository();
}
