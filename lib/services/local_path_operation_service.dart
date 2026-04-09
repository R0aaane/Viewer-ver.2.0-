import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

class LocalPathOperationException implements Exception {
  final String message;

  const LocalPathOperationException(this.message);

  @override
  String toString() => message;
}

enum LocalPathConflictResult {
  none,
  sameFile,
  duplicateName,
}

class LocalPathOperationService {
  static final p.Context _context = p.Context(
    style: Platform.isWindows ? p.Style.windows : p.Style.posix,
  );

  static LocalPathOperationException _duplicateNameException(String targetPath) {
    final targetName = p.basename(targetPath);
    return LocalPathOperationException(
      '同じ名前のファイルまたはフォルダが既に存在します: $targetName',
    );
  }

  static LocalPathOperationException _operationException({
    required String action,
    required String targetPath,
    required bool isDirectory,
    Object? error,
  }) {
    final itemLabel = isDirectory ? 'フォルダ' : 'ファイル';
    final targetName = p.basename(targetPath);

    if (error is FileSystemException) {
      final osMessage = error.osError?.message.trim() ?? '';
      final fileSystemMessage = error.message.trim();
      final details = <String>[
        if (osMessage.isNotEmpty) osMessage,
        if (fileSystemMessage.isNotEmpty && fileSystemMessage != osMessage)
          fileSystemMessage,
      ];
      final suffix = details.isEmpty ? '' : ' (${details.join(' / ')})';
      return LocalPathOperationException(
        '$itemLabelの$actionに失敗しました: $targetName$suffix',
      );
    }

    final reason = '$error'.trim();
    final suffix = reason.isEmpty ? '' : ' ($reason)';
    return LocalPathOperationException(
      '$itemLabelの$actionに失敗しました: $targetName$suffix',
    );
  }

  static String normalize(String rawPath) {
    final normalized = _context.normalize(rawPath);
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  static Future<bool> isSameFile(String sourcePath, String targetPath) async {
    if (normalize(sourcePath) == normalize(targetPath)) {
      return true;
    }

    try {
      return await FileSystemEntity.identical(sourcePath, targetPath);
    } catch (_) {
      return false;
    }
  }

  static Future<LocalPathConflictResult> checkNameConflict({
    required String sourcePath,
    required String targetPath,
  }) async {
    if (await isSameFile(sourcePath, targetPath)) {
      return LocalPathConflictResult.sameFile;
    }

    final targetType = await FileSystemEntity.type(
      targetPath,
      followLinks: false,
    );
    if (targetType != FileSystemEntityType.notFound) {
      return LocalPathConflictResult.duplicateName;
    }
    return LocalPathConflictResult.none;
  }

  static Future<bool> renameItem({
    required String sourcePath,
    required String targetPath,
    required bool isDirectory,
    String logPrefix = 'RENAME',
  }) async {
    debugPrint('[$logPrefix] request old=$sourcePath new=$targetPath');
    final conflict = await checkNameConflict(
      sourcePath: sourcePath,
      targetPath: targetPath,
    );
    if (conflict == LocalPathConflictResult.sameFile) {
      debugPrint('[MOVE] skipped same-file source=$sourcePath target=$targetPath');
      return false;
    }
    if (conflict == LocalPathConflictResult.duplicateName) {
      debugPrint(
        '[COPY] blocked duplicate-name source=$sourcePath target=$targetPath',
      );
      throw _duplicateNameException(targetPath);
    }

    try {
      if (isDirectory) {
        await Directory(sourcePath).rename(targetPath);
      } else {
        await File(sourcePath).rename(targetPath);
      }
      debugPrint('[$logPrefix] success old=$sourcePath new=$targetPath');
      return true;
    } on FileSystemException catch (error, stackTrace) {
      debugPrint('[$logPrefix] failed reason=$error old=$sourcePath new=$targetPath');
      debugPrintStack(label: '[$logPrefix] stack', stackTrace: stackTrace);
      throw _operationException(
        action: '名前の変更',
        targetPath: targetPath,
        isDirectory: isDirectory,
        error: error,
      );
    } catch (error, stackTrace) {
      debugPrint('[$logPrefix] failed reason=$error old=$sourcePath new=$targetPath');
      debugPrintStack(label: '[$logPrefix] stack', stackTrace: stackTrace);
      throw _operationException(
        action: '名前の変更',
        targetPath: targetPath,
        isDirectory: isDirectory,
        error: error,
      );
    }
  }

  static Future<bool> moveItem({
    required String sourcePath,
    required String targetPath,
    String logPrefix = 'MOVE',
  }) async {
    debugPrint('[$logPrefix] request old=$sourcePath new=$targetPath');
    final conflict = await checkNameConflict(
      sourcePath: sourcePath,
      targetPath: targetPath,
    );
    if (conflict == LocalPathConflictResult.sameFile) {
      debugPrint('[MOVE] skipped same-file source=$sourcePath target=$targetPath');
      return false;
    }
    if (conflict == LocalPathConflictResult.duplicateName) {
      debugPrint(
        '[COPY] blocked duplicate-name source=$sourcePath target=$targetPath',
      );
      throw _duplicateNameException(targetPath);
    }

    final source = File(sourcePath);
    try {
      await source.rename(targetPath);
      debugPrint('[$logPrefix] success old=$sourcePath new=$targetPath');
      return true;
    } on FileSystemException catch (error, stackTrace) {
      debugPrint(
        '[$logPrefix] rename fallback reason=$error old=$sourcePath new=$targetPath',
      );
      debugPrintStack(label: '[$logPrefix] stack', stackTrace: stackTrace);
      await source.copy(targetPath);
      await source.delete();
      debugPrint('[$logPrefix] success old=$sourcePath new=$targetPath');
      return true;
    }
  }

  static Future<bool> copyItem({
    required String sourcePath,
    required String targetPath,
    required bool overwrite,
    String logPrefix = 'COPY',
  }) async {
    final conflict = await checkNameConflict(
      sourcePath: sourcePath,
      targetPath: targetPath,
    );
    if (conflict == LocalPathConflictResult.sameFile) {
      debugPrint('[MOVE] skipped same-file source=$sourcePath target=$targetPath');
      return false;
    }
    if (conflict == LocalPathConflictResult.duplicateName && !overwrite) {
      debugPrint(
        '[COPY] blocked duplicate-name source=$sourcePath target=$targetPath',
      );
      throw _duplicateNameException(targetPath);
    }

    final targetFile = File(targetPath);
    if (overwrite && await targetFile.exists()) {
      await targetFile.delete();
    }

    await File(sourcePath).copy(targetPath);
    return true;
  }
}
