import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;

import '../services/app_storage_paths.dart';
import 'app_db.dart';

class DatabaseBackupResult {
  final String savedName;
  final String savedPath;
  final int sizeBytes;

  const DatabaseBackupResult({
    required this.savedName,
    required this.savedPath,
    required this.sizeBytes,
  });
}

class DatabaseBackupService {
  static Future<DatabaseBackupResult> createBackupInAppStorage(AppDb db) async {
    final backupDir = Directory(
      p.join((await getAppStorageDirectory()).path, 'backups'),
    );
    await backupDir.create(recursive: true);

    final target = File(p.join(backupDir.path, _backupFileName()));
    await db.backupToFile(target);
    final stat = await target.stat();

    return DatabaseBackupResult(
      savedName: p.basename(target.path),
      savedPath: target.path,
      sizeBytes: stat.size,
    );
  }

  static Future<DatabaseBackupResult?> exportBackupPickLocation(
    AppDb db,
  ) async {
    final suggestedName = _backupFileName();

    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      final location = await getSaveLocation(
        suggestedName: suggestedName,
        confirmButtonText: 'Save',
        acceptedTypeGroups: const <XTypeGroup>[
          XTypeGroup(label: 'SQLite database', extensions: <String>['sqlite']),
        ],
      );
      final path = location?.path;
      if (path == null || path.isEmpty) {
        return null;
      }

      final target = File(path);
      await db.backupToFile(target);
      final stat = await target.stat();
      return DatabaseBackupResult(
        savedName: p.basename(target.path),
        savedPath: target.path,
        sizeBytes: stat.size,
      );
    }

    return createBackupInAppStorage(db);
  }

  static String _backupFileName() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    return 'media_viewer_backup_$stamp.sqlite';
  }
}
