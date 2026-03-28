import 'dart:io' show Platform;

import '../database/app_db.dart';
import '../models/metadata_settings.dart';
import 'androidFolderRepository.dart';
import 'folderRepository.dart';
import 'mediaRepository.dart';
import 'remote_media_repository.dart';

MediaRepository _createLocalRepository(AppDb db) {
  if (Platform.isAndroid) {
    return AndroidFolderRepository(db);
  }
  return WindowsFolderRepository();
}

MediaRepository createRepository(
  AppDb db, {
  required MetadataSettings initialSettings,
}) {
  final local = _createLocalRepository(db);
  return SwitchingMediaRepository(local, initialSettings: initialSettings);
}
