import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../database/app_db.dart';

/// アプリ設定のバックアップ/復元と Drift DB のバックアップ/復元を扱うサービス。
///
/// - SharedPreferences 系の設定は JSON にシリアライズ
/// - Drift DB（media_viewer.sqlite）はバイナリでバックアップ
///
/// 実際の UI（ダイアログ/スナックバー）は呼び出し側で行う想定。
class AppBackupService {
  AppBackupService(this._db);

  final AppDb _db;

  // バックアップフォーマットのバージョン
  static const int _settingsSchemaVersion = 1;

  /// 設定バックアップをファイルに書き出す（ユーザーに保存先を選ばせる）。
  ///
  /// 正常に書き出せた場合 true、ユーザーキャンセルや失敗時は false を返す。
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
      if (path == null || path.isEmpty) {
        return false; // キャンセル
      }

      final file = File(path);
      await file.create(recursive: true);
      await file.writeAsString(jsonStr);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 設定バックアップ JSON をユーザーに選ばせて読み込み、SharedPreferences に反映する。
  ///
  /// 正常に復元できた場合 true、キャンセル/失敗時は false。
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
      if (decoded is! Map<String, dynamic>) {
        return false;
      }

      await _restoreSettingsFromJson(decoded, prefs);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Drift DB（media_viewer.sqlite）をファイルとしてバックアップする。
  Future<bool> exportDatabaseWithFilePicker() async {
    try {
      final dbFile = await _getDbFile();
      if (!await dbFile.exists()) {
        return false;
      }

      final bytes = await dbFile.readAsBytes();
      final now = DateTime.now();
      final suggestedName =
          'media_viewer_db_${_yyyymmdd_HHmm(now)}.sqlite';

      final location = await getSaveLocation(
        suggestedName: suggestedName,
        confirmButtonText: '保存',
      );
      final path = location?.path;
      if (path == null || path.isEmpty) {
        return false;
      }

      final out = File(path);
      await out.create(recursive: true);
      await out.writeAsBytes(bytes, flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// ユーザーが選んだ SQLite ファイルを現在の DB として復元する。
  ///
  /// 既存 DB は一時ファイルに退避し、復元が成功したら削除する。
  /// 失敗した場合は元の DB を戻す（可能な限りロールバック）。
  ///
  /// 復元後はアプリ再起動が推奨。
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

      final backupFile =
          File(p.join(dir.path, 'media_viewer.sqlite.bak_${DateTime.now().millisecondsSinceEpoch}'));

      // 既存 DB を退避
      if (await dbFile.exists()) {
        await dbFile.copy(backupFile.path);
      }

      try {
        // 新しい DB を書き込み
        await dbFile.writeAsBytes(srcBytes, flush: true);
        return true;
      } catch (_) {
        // 書き込み失敗時はロールバック
        if (await backupFile.exists()) {
          await backupFile.copy(dbFile.path);
        }
        return false;
      } finally {
        // バックアップファイルは成功時/失敗時ともに基本不要
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

  // ----------------------------
  // 設定 JSON の構築/復元
  // ----------------------------

  Future<Map<String, dynamic>> _buildSettingsJson(
    SharedPreferences prefs,
  ) async {
    final folders = prefs.getStringList('prefs.folders') ?? const <String>[];
    final currentFolder = prefs.getString('prefs.currentFolder');
    final favorites =
        prefs.getStringList('prefs.favorites') ?? const <String>[];
    final aliasesJson = prefs.getString('prefs.folderAliasesJson');
    final readerFitMode = prefs.getInt('prefs.readerFitMode');
    final readerTwoPage = prefs.getBool('prefs.readerTwoPage');
    final lastFolderRaw = prefs.getString('prefs.lastFolderRaw');
    final tagsJson = prefs.getString('prefs.tagsJson');
    final folderTileMode = prefs.getInt('prefs.folderTileMode');

    // Drift DB からタグマスター & item-tag 関係も JSON でダンプ（論理バックアップ）
    final tagDump = await _dumpTagsFromDb();

    return <String, dynamic>{
      'schemaVersion': _settingsSchemaVersion,
      'prefs': <String, dynamic>{
        'folders': folders,
        'currentFolder': currentFolder,
        'favorites': favorites,
        'folderAliasesJson': aliasesJson,
        'readerFitMode': readerFitMode,
        'readerTwoPage': readerTwoPage,
        'lastFolderRaw': lastFolderRaw,
        'tagsJson': tagsJson,
        'folderTileMode': folderTileMode,
      },
      'tagDump': tagDump,
    };
  }

  Future<void> _restoreSettingsFromJson(
    Map<String, dynamic> data,
    SharedPreferences prefs,
  ) async {
    final prefsMap = data['prefs'];
    if (prefsMap is Map) {
      final folders = (prefsMap['folders'] as List?)
              ?.map((e) => e.toString())
              .toList(growable: false) ??
          const <String>[];
      final currentFolder = prefsMap['currentFolder']?.toString();
      final favorites = (prefsMap['favorites'] as List?)
              ?.map((e) => e.toString())
              .toList(growable: false) ??
          const <String>[];
      final aliasesJson = prefsMap['folderAliasesJson']?.toString();
      final readerFitMode = _toIntOrNull(prefsMap['readerFitMode']);
      final readerTwoPage = _toBoolOrNull(prefsMap['readerTwoPage']);
      final lastFolderRaw = prefsMap['lastFolderRaw']?.toString();
      final tagsJson = prefsMap['tagsJson']?.toString();
      final folderTileMode = _toIntOrNull(prefsMap['folderTileMode']);

      await prefs.setStringList('prefs.folders', folders);
      if (currentFolder == null || currentFolder.isEmpty) {
        await prefs.remove('prefs.currentFolder');
      } else {
        await prefs.setString('prefs.currentFolder', currentFolder);
      }
      await prefs.setStringList('prefs.favorites', favorites);

      if (aliasesJson == null || aliasesJson.isEmpty) {
        await prefs.remove('prefs.folderAliasesJson');
      } else {
        await prefs.setString('prefs.folderAliasesJson', aliasesJson);
      }

      if (readerFitMode == null) {
        await prefs.remove('prefs.readerFitMode');
      } else {
        await prefs.setInt('prefs.readerFitMode', readerFitMode);
      }

      if (readerTwoPage == null) {
        await prefs.remove('prefs.readerTwoPage');
      } else {
        await prefs.setBool('prefs.readerTwoPage', readerTwoPage);
      }

      if (lastFolderRaw == null || lastFolderRaw.isEmpty) {
        await prefs.remove('prefs.lastFolderRaw');
      } else {
        await prefs.setString('prefs.lastFolderRaw', lastFolderRaw);
      }

      if (tagsJson == null || tagsJson.isEmpty) {
        await prefs.remove('prefs.tagsJson');
      } else {
        await prefs.setString('prefs.tagsJson', tagsJson);
      }

      if (folderTileMode == null) {
        await prefs.remove('prefs.folderTileMode');
      } else {
        await prefs.setInt('prefs.folderTileMode', folderTileMode);
      }
    }

    // tagDump は DB 上書きと競合しやすいので、現状は読み取りのみ（DBは別途 sqlite バックアップで扱う）
  }

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
    // Drift の自動生成クラスを通じて単純に全件ダンプする。
    final mediaItems = await _db.select(_db.mediaItems).get();
    final tags = await _db.select(_db.tags).get();
    final links = await _db.select(_db.mediaItemTags).get();

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
    };
  }

  Future<File> _getDbFile() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'media_viewer.sqlite');
    return File(path);
  }

  String _yyyymmdd_HHmm(DateTime dt) {
    String two(int v) => v.toString().padLeft(2, '0');
    final y = dt.year.toString().padLeft(4, '0');
    final m = two(dt.month);
    final d = two(dt.day);
    final hh = two(dt.hour);
    final mm = two(dt.minute);
    return '$y$m${d}_$hh$mm';
  }
}

