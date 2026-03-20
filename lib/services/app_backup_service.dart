import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../database/app_db.dart';

class AppBackupService {
  AppBackupService(this._db);

  final AppDb _db;

  static const int _settingsSchemaVersion = 2;

  // SharedPreferences 側で現在使っているキー
  static const String _kFolders = 'prefs.folders';
  static const String _kCurrentFolder = 'prefs.currentFolder';
  static const String _kFavorites = 'prefs.favorites';
  static const String _kFolderAliasesJson = 'prefs.folderAliasesJson';
  static const String _kReaderFitMode = 'prefs.readerFitMode';
  static const String _kReaderTwoPage = 'prefs.readerTwoPage';
  static const String _kLastFolderRaw = 'prefs.lastFolderRaw';
  static const String _kTagsJson = 'prefs.tagsJson'; // 旧互換用
  static const String _kFolderTileMode = 'prefs.folderTileMode';

  Future<bool> exportSettingsWithFilePicker(SharedPreferences prefs) async {
    try {
      final jsonMap = await _buildSettingsJson(prefs);
      final jsonStr = const JsonEncoder.withIndent('  ').convert(jsonMap);

      final now = DateTime.now();
      final suggestedName =
          'media_viewer_settings_${_yyyymmdd_HHmm(now)}.json';

      final location = await getSaveLocation(
        suggestedName: suggestedName,
        confirmButtonText: '保存',
      );
      final path = location?.path;
      if (path == null || path.isEmpty) return false;

      final file = File(path);
      await file.create(recursive: true);
      await file.writeAsString(jsonStr, flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> importSettingsWithFilePicker(SharedPreferences prefs) async {
    try {
      final typeGroup = XTypeGroup(
        label: 'Settings JSON',
        extensions: const ['json'],
      );
      final file = await openFile(acceptedTypeGroups: [typeGroup]);
      if (file == null) return false;

      final jsonStr = await file.readAsString();
      final dynamic decoded = jsonDecode(jsonStr);
      if (decoded is! Map<String, dynamic>) return false;

      await _restoreSettingsFromJson(decoded, prefs);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// DBのバイナリバックアップ
  ///
  /// 注意:
  /// - タグやメディア索引など、現在の主データは Drift DB 側
  /// - そのため完全バックアップはこの DB バックアップを使う
  Future<bool> exportDatabaseWithFilePicker() async {
    try {
      final dbFile = await _getDbFile();
      if (!await dbFile.exists()) return false;

      // 念のため一時コピーを作ってから書き出す
      final tempDir = await getTemporaryDirectory();
      final tempCopy = File(
        p.join(
          tempDir.path,
          'media_viewer_export_${DateTime.now().millisecondsSinceEpoch}.sqlite',
        ),
      );

      await dbFile.copy(tempCopy.path);
      final bytes = await tempCopy.readAsBytes();

      final now = DateTime.now();
      final suggestedName = 'media_viewer_db_${_yyyymmdd_HHmm(now)}.sqlite';

      final location = await getSaveLocation(
        suggestedName: suggestedName,
        confirmButtonText: '保存',
      );
      final path = location?.path;
      if (path == null || path.isEmpty) {
        try {
          await tempCopy.delete();
        } catch (_) {}
        return false;
      }

      final out = File(path);
      await out.create(recursive: true);
      await out.writeAsBytes(bytes, flush: true);

      try {
        await tempCopy.delete();
      } catch (_) {}

      return true;
    } catch (_) {
      return false;
    }
  }

  /// DB復元
  ///
  /// 重要:
  /// - いま開いている Drift 接続を閉じてから置き換える
  /// - この呼び出し後はアプリ再起動前提
  Future<bool> importDatabaseWithFilePicker() async {
    try {
      final typeGroup = XTypeGroup(
        label: 'SQLite DB',
        extensions: const ['sqlite', 'db'],
      );
      final picked = await openFile(acceptedTypeGroups: [typeGroup]);
      if (picked == null) return false;

      final srcBytes = await picked.readAsBytes();
      if (srcBytes.isEmpty) return false;

      final dbFile = await _getDbFile();
      final dir = dbFile.parent;
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      final backupFile = File(
        p.join(
          dir.path,
          'media_viewer.sqlite.bak_${DateTime.now().millisecondsSinceEpoch}',
        ),
      );

      try {
        // 開いているDBを閉じる
        await _db.close();
      } catch (_) {
        // close失敗でも続行はするが、復元成功率は下がる
      }

      if (await dbFile.exists()) {
        await dbFile.copy(backupFile.path);
      }

      try {
        await dbFile.writeAsBytes(srcBytes, flush: true);
        return true;
      } catch (_) {
        if (await backupFile.exists()) {
          await backupFile.copy(dbFile.path);
        }
        return false;
      } finally {
        if (await backupFile.exists()) {
          try {
            await backupFile.delete();
          } catch (_) {}
        }
      }
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> _buildSettingsJson(
    SharedPreferences prefs,
  ) async {
    return <String, dynamic>{
      'schemaVersion': _settingsSchemaVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'prefs': <String, dynamic>{
        'folders': prefs.getStringList(_kFolders) ?? const <String>[],
        'currentFolder': prefs.getString(_kCurrentFolder),
        'favorites': prefs.getStringList(_kFavorites) ?? const <String>[],
        'folderAliasesJson': prefs.getString(_kFolderAliasesJson),
        'readerFitMode': prefs.getInt(_kReaderFitMode),
        'readerTwoPage': prefs.getBool(_kReaderTwoPage),
        'lastFolderRaw': prefs.getString(_kLastFolderRaw),
        'tagsJson': prefs.getString(_kTagsJson), // 旧互換
        'folderTileMode': prefs.getInt(_kFolderTileMode),
      },

      // 参考情報として残すだけ。復元はDBバックアップで行う。
      'tagDump': await _dumpTagsFromDb(),
    };
  }

  Future<void> _restoreSettingsFromJson(
    Map<String, dynamic> data,
    SharedPreferences prefs,
  ) async {
    final prefsMap = data['prefs'];
    if (prefsMap is! Map) return;

    final folders = (prefsMap['folders'] as List?)
            ?.map((e) => e.toString())
            .toList(growable: false) ??
        const <String>[];

    final currentFolder = _stringOrNull(prefsMap['currentFolder']);
    final favorites = (prefsMap['favorites'] as List?)
            ?.map((e) => e.toString())
            .toList(growable: false) ??
        const <String>[];

    final aliasesJson = _stringOrNull(prefsMap['folderAliasesJson']);
    final readerFitMode = _toIntOrNull(prefsMap['readerFitMode']);
    final readerTwoPage = _toBoolOrNull(prefsMap['readerTwoPage']);
    final lastFolderRaw = _stringOrNull(prefsMap['lastFolderRaw']);
    final tagsJson = _stringOrNull(prefsMap['tagsJson']);
    final folderTileMode = _toIntOrNull(prefsMap['folderTileMode']);

    await prefs.setStringList(_kFolders, folders);

    if (_isBlank(currentFolder)) {
      await prefs.remove(_kCurrentFolder);
    } else {
      await prefs.setString(_kCurrentFolder, currentFolder!);
    }

    await prefs.setStringList(_kFavorites, favorites);

    if (_isBlank(aliasesJson)) {
      await prefs.remove(_kFolderAliasesJson);
    } else {
      await prefs.setString(_kFolderAliasesJson, aliasesJson!);
    }

    if (readerFitMode == null) {
      await prefs.remove(_kReaderFitMode);
    } else {
      await prefs.setInt(_kReaderFitMode, readerFitMode);
    }

    if (readerTwoPage == null) {
      await prefs.remove(_kReaderTwoPage);
    } else {
      await prefs.setBool(_kReaderTwoPage, readerTwoPage);
    }

    if (_isBlank(lastFolderRaw)) {
      await prefs.remove(_kLastFolderRaw);
    } else {
      await prefs.setString(_kLastFolderRaw, lastFolderRaw!);
    }

    if (_isBlank(tagsJson)) {
      await prefs.remove(_kTagsJson);
    } else {
      await prefs.setString(_kTagsJson, tagsJson!);
    }

    if (folderTileMode == null) {
      await prefs.remove(_kFolderTileMode);
    } else {
      await prefs.setInt(_kFolderTileMode, folderTileMode);
    }
  }

  String? _stringOrNull(Object? v) {
    if (v == null) return null;
    final s = v.toString();
    return s;
  }

  bool _isBlank(String? s) => s == null || s.trim().isEmpty;

  int? _toIntOrNull(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is double) return v.toInt();
    return int.tryParse(v.toString());
  }

  bool? _toBoolOrNull(Object? v) {
    if (v == null) return null;
    if (v is bool) return v;
    final s = v.toString().toLowerCase();
    if (s == 'true') return true;
    if (s == 'false') return false;
    return null;
  }

  Future<Map<String, dynamic>> _dumpTagsFromDb() async {
    final mediaItems = await _db.select(_db.mediaItems).get();
    final tags = await _db.select(_db.tags).get();
    final links = await _db.select(_db.mediaItemTags).get();
    final folderIndexes = await _db.select(_db.folderIndexes).get();
    final folderEntries = await _db.select(_db.folderEntries).get();

    return <String, dynamic>{
      'mediaItems': mediaItems
          .map((m) => {
                'id': m.id,
                'folderRaw': m.folderRaw,
                'displayName': m.displayName,
                'kind': m.kind,
                'modifiedEpochMs': m.modifiedEpochMs,
              })
          .toList(growable: false),
      'tags': tags
          .map((t) => {
                'tagId': t.tagId,
                'name': t.name,
                'category': t.category,
              })
          .toList(growable: false),
      'mediaItemTags': links
          .map((l) => {
                'itemId': l.itemId,
                'tagId': l.tagId,
              })
          .toList(growable: false),
      'folderIndexes': folderIndexes
          .map((f) => {
                'folderRaw': f.folderRaw,
                'scannedAtEpochMs': f.scannedAtEpochMs,
                'totalCount': f.totalCount,
              })
          .toList(growable: false),
      'folderEntries': folderEntries
          .map((e) => {
                'folderRaw': e.folderRaw,
                'entryId': e.entryId,
                'displayName': e.displayName,
                'kind': e.kind,
                'modifiedEpochMs': e.modifiedEpochMs,
                'sortName': e.sortName,
              })
          .toList(growable: false),
    };
  }

  Future<File> _getDbFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, 'media_viewer.sqlite'));
  }

  String _yyyymmdd_HHmm(DateTime dt) {
    String two(int v) => v.toString().padLeft(2, '0');
    final y = dt.year.toString().padLeft(4, '0');
    final m = two(dt.month);
    final d = two(dt.day);
    final hh = two(dt.hour);
    final mm = two(dt.minute);
    return '${y}${m}${d}_$hh$mm';
  }
}