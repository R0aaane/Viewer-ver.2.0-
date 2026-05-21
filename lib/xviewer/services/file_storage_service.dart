import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/storage_keys.dart';

class FileStorageService {
  Future<String> saveBytes({
    required Uint8List bytes,
    required String fileName,
    String? accountFolderName,
  }) async {
    final directory = await _ensureImageDirectory(
      accountFolderName: accountFolderName,
    );
    final filePath = p.join(directory.path, fileName);
    final file = File(filePath);
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<void> deleteFile(String filePath) async {
    final file = File(filePath);
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<String> getBaseDirectoryPath({String? accountFolderName}) async {
    final directory = await _ensureImageDirectory(
      accountFolderName: accountFolderName,
    );
    return directory.path;
  }

  Future<void> setSavedImagesDirectory(String path) async {
    final normalized = path.trim();
    final prefs = await SharedPreferences.getInstance();
    if (normalized.isEmpty) {
      await prefs.remove(StorageKeys.savedImagesDirectory);
      return;
    }
    await Directory(normalized).create(recursive: true);
    await prefs.setString(StorageKeys.savedImagesDirectory, normalized);
  }

  Future<void> resetSavedImagesDirectory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(StorageKeys.savedImagesDirectory);
  }

  Future<String?> _loadConfiguredDirectoryPath() async {
    final prefs = await SharedPreferences.getInstance();
    final configured = prefs
        .getString(StorageKeys.savedImagesDirectory)
        ?.trim();
    return configured == null || configured.isEmpty ? null : configured;
  }

  Future<List<File>> listSavedImageFiles() async {
    final directory = await _ensureImageDirectory();
    final files = <File>[];
    await for (final entity in directory.list(recursive: true)) {
      if (entity is! File) {
        continue;
      }

      final extension = p.extension(entity.path).toLowerCase();
      if (const {
        '.jpg',
        '.jpeg',
        '.png',
        '.webp',
        '.gif',
      }.contains(extension)) {
        files.add(entity);
      }
    }
    return files;
  }

  Future<String> moveFileToDirectory({
    required String sourcePath,
    required String fileName,
    String? accountFolderName,
  }) async {
    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) {
      throw FileSystemException('Source file not found', sourcePath);
    }

    final directory = await _ensureImageDirectory(
      accountFolderName: accountFolderName,
    );
    final destinationPath = p.join(directory.path, fileName);
    if (p.normalize(sourceFile.path) == p.normalize(destinationPath)) {
      return sourceFile.path;
    }

    final destinationFile = File(destinationPath);
    if (await destinationFile.exists()) {
      await sourceFile.delete();
      return destinationFile.path;
    }

    try {
      final moved = await sourceFile.rename(destinationPath);
      return moved.path;
    } on FileSystemException {
      await destinationFile.writeAsBytes(
        await sourceFile.readAsBytes(),
        flush: true,
      );
      await sourceFile.delete();
      return destinationFile.path;
    }
  }

  Future<Directory> _ensureImageDirectory({String? accountFolderName}) async {
    final configuredPath = await _loadConfiguredDirectoryPath();
    final basePath =
        configuredPath ??
        p.join((await getApplicationDocumentsDirectory()).path, 'Saved_images');
    final pathSegments = <String>[basePath];
    final normalizedFolderName = accountFolderName?.trim();
    if (normalizedFolderName != null && normalizedFolderName.isNotEmpty) {
      pathSegments.add(normalizedFolderName);
    }
    final imageDir = Directory(p.joinAll(pathSegments));
    if (!await imageDir.exists()) {
      await imageDir.create(recursive: true);
    }
    return imageDir;
  }
}
