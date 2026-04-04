import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const String _appStorageFolderName = 'PDF_Viewer';
const String _databaseFileName = 'media_viewer.sqlite';
const String _hostApiFolderName = 'host_api';

Future<Directory> getAppStorageDirectory() async {
  final docsDir = await getApplicationDocumentsDirectory();
  final appDir = Directory(p.join(docsDir.path, _appStorageFolderName));
  if (!await appDir.exists()) {
    await appDir.create(recursive: true);
  }
  return appDir;
}

Future<File> getAppDatabaseFile() async {
  final docsDir = await getApplicationDocumentsDirectory();
  final appDir = await getAppStorageDirectory();
  final legacyFile = File(p.join(docsDir.path, _databaseFileName));
  final targetFile = File(p.join(appDir.path, _databaseFileName));
  await _migrateLegacyFileIfNeeded(legacyFile, targetFile);
  return targetFile;
}

Future<Directory> getHostApiDataDirectory() async {
  final docsDir = await getApplicationDocumentsDirectory();
  final appDir = await getAppStorageDirectory();
  final legacyDir = Directory(p.join(docsDir.path, _hostApiFolderName));
  final targetDir = Directory(p.join(appDir.path, _hostApiFolderName));
  await _migrateLegacyDirectoryIfNeeded(legacyDir, targetDir);
  if (!await targetDir.exists()) {
    await targetDir.create(recursive: true);
  }
  return targetDir;
}

Future<void> _migrateLegacyFileIfNeeded(
  File legacyFile,
  File targetFile,
) async {
  if (legacyFile.path == targetFile.path || !await legacyFile.exists()) {
    return;
  }
  if (await targetFile.exists()) {
    return;
  }

  await targetFile.parent.create(recursive: true);
  try {
    await legacyFile.rename(targetFile.path);
  } on FileSystemException {
    await legacyFile.copy(targetFile.path);
    await legacyFile.delete();
  }
}

Future<void> _migrateLegacyDirectoryIfNeeded(
  Directory legacyDir,
  Directory targetDir,
) async {
  if (legacyDir.path == targetDir.path || !await legacyDir.exists()) {
    return;
  }
  if (await targetDir.exists()) {
    return;
  }

  await targetDir.parent.create(recursive: true);
  try {
    await legacyDir.rename(targetDir.path);
  } on FileSystemException {
    await _copyDirectoryRecursively(legacyDir, targetDir);
    await legacyDir.delete(recursive: true);
  }
}

Future<void> _copyDirectoryRecursively(
  Directory source,
  Directory destination,
) async {
  await destination.create(recursive: true);
  await for (final entity in source.list(recursive: false)) {
    final name = p.basename(entity.path);
    final targetPath = p.join(destination.path, name);
    if (entity is File) {
      await entity.copy(targetPath);
      continue;
    }
    if (entity is Directory) {
      await _copyDirectoryRecursively(entity, Directory(targetPath));
    }
  }
}
