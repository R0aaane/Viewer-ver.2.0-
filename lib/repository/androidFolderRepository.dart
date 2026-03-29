import 'dart:async';
import 'dart:io';
import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:convert';

import 'package:docman/docman.dart';
import 'package:pdfx/pdfx.dart';
import 'package:path_provider/path_provider.dart';
import 'package:drift/drift.dart' as drift;

import '../media_file_types.dart';
import '../models/folder.dart';
import '../models/mediaItem.dart';
import '../models/metadata_settings.dart';
import 'mediaRepository.dart';

import '../database/app_db.dart' as db;

class AndroidFolderRepository implements MediaRepository {
  final db.AppDb _db;
  AndroidFolderRepository(this._db);

  @override
  RepositoryCapabilities get capabilities => const RepositoryCapabilities(
    canRename: true,
    canDelete: true,
    canUpload: true,
    canRecursiveSearch: true,
    canExportPdf: true,
    canOrganizeLibrary: true,
    canPickFolder: true,
    canAddLocalFolder: true,
    canImportToHost: false,
    canBatchUpload: true,
    canAssignImportTags: true,
  );

  @override
  AppMode get appMode => AppMode.standalone;

  @override
  bool get isRemoteMode => false;

  @override
  bool get isHostMode => false;

  @override
  bool get canImportFromUrl => false;

  @override
  Future<void> reloadSettings() async {}

  @override
  Future<List<FolderHandle>> listAvailableFolders() async =>
      const <FolderHandle>[];

  // インデックスの有効期限
  static const Duration _folderIndexTtl = Duration(minutes: 10);

  // 対象ファイルの拡張子（小文字）
  static const Set<String> _imageExt = MediaFileTypes.imageExtensions;
  static const _pdfExt = '.pdf';
  static const Duration _safShallowTtl = Duration(seconds: 15);

  final _AsyncMutex _docmanMutex = _AsyncMutex();

  Future<T> _docmanSync<T>(Future<T> Function() action) {
    return _docmanMutex.synchronized(action);
  }
  
  // SAF shallow cache（直下一覧/ソート済み）
  final Map<String, _ShallowCacheEntry> _safShallowCache = {};

  final _LruCache<String, ThumbPair> _thumbCache = _LruCache<String, ThumbPair>(
    maxBytes: 64 * 1024 * 1024,
    maxEntries: 400,
    sizeOf: (pair) =>
        pair.front.lengthInBytes + (pair.back?.lengthInBytes ?? 0),
  );
  

  // PDF操作は並列不可なのでURI単位でロック
  final Map<String, _AsyncMutex> _pdfLocks = {};
  _AsyncMutex _lockOf(String uri) =>
      _pdfLocks.putIfAbsent(uri, () => _AsyncMutex());

  final Map<String, Future<ThumbPair>> _thumbInFlight = {};

  // ★ PDFキャッシュ（無限に増えるのを防ぐ）
  final LinkedHashMap<String, PdfDocument> _pdfCache = LinkedHashMap();
  static const int _pdfCacheMaxEntries = 6;

  final Map<String, Future<void>> _folderIndexInFlight = {};

  //一度に読み込むレンダリングを制限
  int _thumbActive = 0;
  final List<Completer<void>> _thumbWaiters = [];
  
  Future<void> _acquireThumbSlot([int max = 2]) async {
    if (_thumbActive < max) {
      _thumbActive++;
      return;
    }
    final c = Completer<void>();
    _thumbWaiters.add(c);
    await c.future;
    _thumbActive++;
  }
  
  void _releaseThumbSlot() {
    _thumbActive--;
    if (_thumbWaiters.isNotEmpty) {
      _thumbWaiters.removeAt(0).complete();
    }
  }

  int _entryKindToMediaKind(int k) {
  final e = db.FolderEntryKindDb.values[k];
  switch (e) {
    case db.FolderEntryKindDb.folder:
      return 2; // 仮（使わない）
    case db.FolderEntryKindDb.image:
      return 0;
    case db.FolderEntryKindDb.pdf:
      return 1;
  }
}

MediaKind _dbKindToMediaKind(int k) {
  final e = db.FolderEntryKindDb.values[k];
  switch (e) {
    case db.FolderEntryKindDb.folder:
      return MediaKind.folder;
    case db.FolderEntryKindDb.image:
      return MediaKind.image;
    case db.FolderEntryKindDb.pdf:
      return MediaKind.pdf;
  }
}

int _mediaKindToFolderEntryKind(MediaKind k) {
  switch (k) {
    case MediaKind.folder:
      return db.FolderEntryKindDb.folder.index;
    case MediaKind.image:
      return db.FolderEntryKindDb.image.index;
    case MediaKind.pdf:
      return db.FolderEntryKindDb.pdf.index;
  }
}

String _sortKey(String name) => name.trim().toLowerCase();

Future<db.DbFolderIndex?> _getFolderIndexRow(String folderRaw) {
  return (_db.select(_db.folderIndexes)..where((t) => t.folderRaw.equals(folderRaw)))
      .getSingleOrNull();
}

bool _isIndexFresh(db.DbFolderIndex idx) {
  final scanned = DateTime.fromMillisecondsSinceEpoch(idx.scannedAtEpochMs);
  return DateTime.now().difference(scanned) <= _folderIndexTtl;
}

Future<PagedMediaResult?> _tryListPageFromDb(
  FolderHandle folder, {
  required int offset,
  required int limit,
}) async {
  final raw = folder.raw;
  final idx = await _getFolderIndexRow(raw);
  if (idx == null) return null;

  final q = _db.select(_db.folderEntries)
    ..where((t) => t.folderRaw.equals(raw))
    ..orderBy([
      (t) => drift.OrderingTerm.asc(t.kind),      // folder(0) -> image(1) -> pdf(2)
      (t) => drift.OrderingTerm.asc(t.sortName),  // name sort
    ])
    ..limit(limit, offset: offset);

  final rows = await q.get();

  final items = rows.map((r) {
    final kind = _dbKindToMediaKind(r.kind);
    return MediaItem(
      id: r.entryId,
      displayName: r.displayName,
      kind: kind,
      folderRaw: raw,
      modified: r.modifiedEpochMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(r.modifiedEpochMs!),
      tags: const [],
    );
  }).toList(growable: false);

  return PagedMediaResult(items: items, total: idx.totalCount);
}

  /// SAF直下をスキャンしてDBへ保存（差分は「全入れ替え」で簡単・堅牢）
  Future<void> _rebuildFolderIndexSaf(String folderRaw) async {
    // SAF直下
    final entries = await _safListShallow(folderRaw);

    // 対象だけ + kind決定
    final out = <db.FolderEntriesCompanion>[];
    for (final e in entries) {
      if (e.isDir) {
        out.add(db.FolderEntriesCompanion.insert(
          folderRaw: folderRaw,
          entryId: e.documentUri,
          displayName: e.name,
          kind: db.FolderEntryKindDb.folder.index,
          modifiedEpochMs: drift.Value(e.modified?.millisecondsSinceEpoch),
          sortName: _sortKey(e.name),
        ));
        continue;
      }

      final ext = _lowerExt(e.name);
      if (ext == _pdfExt) {
        out.add(db.FolderEntriesCompanion.insert(
          folderRaw: folderRaw,
          entryId: e.documentUri,
          displayName: e.name,
          kind: db.FolderEntryKindDb.pdf.index,
          modifiedEpochMs: drift.Value(e.modified?.millisecondsSinceEpoch),
          sortName: _sortKey(e.name),
        ));
        continue;
      }
      if (_imageExt.contains(ext)) {
        out.add(db.FolderEntriesCompanion.insert(
          folderRaw: folderRaw,
          entryId: e.documentUri,
          displayName: e.name,
          kind: db.FolderEntryKindDb.image.index,
          modifiedEpochMs: drift.Value(e.modified?.millisecondsSinceEpoch),
          sortName: _sortKey(e.name),
        ));
        continue;
      }
    }

    // sort（DB orderByでも整うが totalCount を正確に）
    out.sort((a, b) {
      final ak = a.kind.value;
      final bk = b.kind.value;
      if (ak != bk) return ak.compareTo(bk);
      return a.sortName.value.compareTo(b.sortName.value);
    });

    final total = out.length;
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    await _db.transaction(() async {
      // 既存削除 → 作り直し（整合性が一番強い）
      await (_db.delete(_db.folderEntries)..where((t) => t.folderRaw.equals(folderRaw))).go();

      await _db.into(_db.folderIndexes).insertOnConflictUpdate(
        db.FolderIndexesCompanion.insert(
          folderRaw: folderRaw,
          scannedAtEpochMs: nowMs,
          totalCount: total,
        ),
      );

      if (out.isNotEmpty) {
        await _db.batch((b) {
          b.insertAll(_db.folderEntries, out, mode: drift.InsertMode.insertOrReplace);
        });
      }
    });
  }

  Future<void> _ensureFolderIndexSaf(String folderRaw, {bool force = false}) async {
    final idx = await _getFolderIndexRow(folderRaw);
    if (!force && idx != null && _isIndexFresh(idx)) return;

    final inflight = _folderIndexInFlight[folderRaw];
    if (inflight != null) return inflight;

    final fut = _rebuildFolderIndexSaf(folderRaw).whenComplete(() {
      _folderIndexInFlight.remove(folderRaw);
    });

    _folderIndexInFlight[folderRaw] = fut;
    return fut;
  }

  Future<void> _invalidateFolderIndex(String folderRaw) async {
    await _db.transaction(() async {
      await (_db.delete(_db.folderEntries)..where((t) => t.folderRaw.equals(folderRaw))).go();
      await (_db.delete(_db.folderIndexes)..where((t) => t.folderRaw.equals(folderRaw))).go();
    });
  }

  // --- 追加: サムネのディスクキャッシュ ---
  Directory? _thumbDiskDir;

  Future<Directory> _ensureThumbDiskDir() async {
    if (_thumbDiskDir != null) return _thumbDiskDir!;
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/thumbs_v1');
    if (!await dir.exists()) await dir.create(recursive: true);
    _thumbDiskDir = dir;
    return dir;
  }

  // 依存を増やさない簡易ハッシュ（FNV-1a 64bit）
  String _fnv1a64Hex(String s) {
    const int fnvOffset = 0xcbf29ce484222325;
    const int fnvPrime = 0x100000001b3;

    int hash = fnvOffset;
    final bytes = utf8.encode(s);
    for (final b in bytes) {
      hash ^= b;
      hash = (hash * fnvPrime) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  Future<File> _thumbDiskFile(String cacheKey) async {
    final dir = await _ensureThumbDiskDir();
    final name = _fnv1a64Hex(cacheKey);
    return File('${dir.path}/$name.bin'); // front bytes だけ保存
  }

  // ==============================
  // SAF アダプタ（docman）
  // ==============================

  Future<String?> _safPickTreeUri() async {
    final dir = await DocMan.pick.directory();
    return dir?.uri;
  }

  DateTime? _toDateTimeSafe(Object? lm) {
    // docman / provider 差を吸収（int / int? / null どれでもOK）
    if (lm is int) {
      if (lm <= 0) return null;
      return DateTime.fromMillisecondsSinceEpoch(lm);
    }
    return null;
  }

  Future<List<_SafEntry>> _safListShallow(String dirUri) async {
    return _docmanSync(() async {
      final dir = await DocumentFile.fromUri(dirUri);
      if (dir == null) return const [];
      if (dir.isDirectory != true) return const [];

      final children = await dir.listDocuments();

      String _fallbackNameFromUri(String uri) {
        try {
          final u = Uri.parse(uri);
          for (int i = u.pathSegments.length - 1; i >= 0; i--) {
            final s = u.pathSegments[i].trim();
            if (s.isNotEmpty) return Uri.decodeComponent(s);
          }
        } catch (_) {}
        return '(no name)';
      }

      final out = <_SafEntry>[];
      for (final f in children) {
        final rawName = (f.name ?? '').trim();
        final isDir = f.isDirectory == true;

        final name =
            rawName.isNotEmpty ? rawName : (isDir ? _fallbackNameFromUri(f.uri) : '');
        if (name.isEmpty) continue;

        out.add(_SafEntry(
          documentUri: f.uri,
          name: name,
          modified: null, // 変更日時は一旦取らない（重い＆docmanのバージョン差が大きい）
          isDir: isDir,
        ));
      }
      return out;
    });
  }

  Future<Uint8List> _safReadBytes(String documentUri) async {
    return _docmanSync(() async {
      final doc = await DocumentFile.fromUri(documentUri);
      if (doc == null) {
        throw Exception('DocumentFile.fromUri failed: $documentUri');
      }
      if (doc.isDirectory == true) {
        throw Exception('Tried to read directory as file: $documentUri');
      }

      final cached = await doc.cache();
      if (cached == null) {
        throw Exception('cache() failed: $documentUri');
      }

      final fb = await cached.readAsBytes();
      if (fb.isEmpty) {
        throw Exception('cached file is empty: $documentUri');
      }
      return fb;
    });
  }

  // ==============================
  // MediaRepository
  // ==============================

  @override
  Future<FolderHandle> getAppLibraryFolder() async {
    final base = await getApplicationDocumentsDirectory();
    final libDir = Directory('${base.path}/library');
    if (!await libDir.exists()) {
      await libDir.create(recursive: true);
    }
    return FolderHandle(libDir.path);
  }

  @override
  Future<FolderHandle?> pickFolder() async {
    final treeUri = await _safPickTreeUri();
    if (treeUri == null || treeUri.isEmpty) return null;
    return FolderHandle(treeUri);
  }

  @override
  Future<MediaItem?> pickSinglePdf() async {
    final items = await pickExternalMediaFiles(
      allowMultiple: false,
      includeImages: false,
      includePdf: true,
    );
    if (items.isEmpty) return null;
    return items.first;
  }

  @override
  Future<List<MediaItem>> pickExternalMediaFiles({
    bool allowMultiple = true,
    bool includeImages = true,
    bool includePdf = true,
  }) async {
    final extensions = <String>[
      if (includeImages) ...MediaFileTypes.imagePickerExtensions,
      if (includePdf) 'pdf',
    ];
    if (extensions.isEmpty) return const [];

    final picked = await DocMan.pick.files(
      extensions: extensions,
      limit: allowMultiple ? 200 : 1,
    );
    if (picked.isEmpty) return const [];

    final rawItems = picked
        .map(_pickedDocIdentifier)
        .whereType<String>()
        .where((value) => value.trim().isNotEmpty)
        .toList(growable: false);
    return resolveExternalItems(rawItems);
  }

  @override
  Future<List<MediaItem>> resolveExternalItems(List<String> rawItems) async {
    final items = <MediaItem>[];
    for (final raw in rawItems) {
      final item = await _externalItemFromRaw(raw);
      if (item != null) {
        items.add(item);
      }
    }
    return items;
  }

  @override
  Future<List<MediaItem>> listMedia(
    FolderHandle folder, {
    void Function(int processed, int total)? onProgress,
  }) async {
    final raw = folder.raw;

    if (raw.startsWith('content://')) {
      return _listMediaSaf(folder, onProgress: onProgress);
    } else {
      return _listMediaFs(folder, onProgress: onProgress);
    }
  }

  @override
  Future<int> countMedia(FolderHandle folder) async {
    final raw = folder.raw;

    if (raw.startsWith('content://')) {
      final idx = await _getFolderIndexRow(raw);
      if (idx != null && _isIndexFresh(idx)) return idx.totalCount;

      // 無い/古いなら作る
      await _ensureFolderIndexSaf(raw, force: true);
      final idx2 = await _getFolderIndexRow(raw);
      return idx2?.totalCount ?? 0;
    }

    final dir = Directory(raw);
    if (!await dir.exists()) return 0;

    int total = 0;
    await for (final ent in dir.list(recursive: false, followLinks: false)) {
      if (ent is Directory) {
        total++;
      } else if (ent is File) {
        final name = ent.uri.pathSegments.isNotEmpty ? ent.uri.pathSegments.last : ent.path;
        if (_isTargetFileName(name)) total++;
      }
    }
    return total;
  }

  @override
  Future<PagedMediaResult> listMediaPage(
    FolderHandle folder, {
    required int offset,
    required int limit,
    void Function(int processed, int total)? onProgress,
  }) async {
    final raw = folder.raw;

    if (raw.startsWith('content://')) {
      // 1) まずDBから即返す（もしあれば）
      final cached = await _tryListPageFromDb(folder, offset: offset, limit: limit);
      if (cached != null) {
        // 2) TTL切れなら裏で更新（UIは即表示のまま）
        final idx = await _getFolderIndexRow(raw);
        if (idx != null && !_isIndexFresh(idx)) {
          // ignore: unawaited_futures
          _ensureFolderIndexSaf(raw); 
        }
        return cached;
      }

      // DBに無い（初回）なら: スキャンしてDB作成 → DBから返す
      await _ensureFolderIndexSaf(raw, force: true);
      final after = await _tryListPageFromDb(folder, offset: offset, limit: limit);
      return after ?? const PagedMediaResult(items: [], total: 0);
    }
    // FS (直下)
    final dir = Directory(raw);
    if (!await dir.exists()) return const PagedMediaResult(items: [], total: 0);

    final dirItems = <MediaItem>[];
    final fileItems = <MediaItem>[];

    await for (final ent in dir.list(recursive: false, followLinks: false)) {
      if (ent is Directory) {
        dirItems.add(MediaItem(
          id: ent.path,
          displayName: _fileName(ent.path),
          kind: MediaKind.folder,
          folderRaw: folder.raw,
          modified: null,
          tags: const [],
        ));
      } else if (ent is File) {
        final name = ent.uri.pathSegments.isNotEmpty ? ent.uri.pathSegments.last : ent.path;
        if (!_isTargetFileName(name)) continue;

        final ext = _lowerExt(name);
        final kind = (ext == _pdfExt) ? MediaKind.pdf : MediaKind.image;
        final stat = await ent.stat();

        fileItems.add(MediaItem(
          id: ent.path,
          displayName: name,
          kind: kind,
          folderRaw: folder.raw,
          modified: stat.modified,
          tags: const [],
        ));
      }
    }

    dirItems.sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    fileItems.sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));

    final all = <MediaItem>[...dirItems, ...fileItems];
    final total = all.length;

    final start = offset.clamp(0, total);
    final end = (start + limit).clamp(0, total);
    final slice = all.sublist(start, end);

    if (onProgress != null) onProgress(slice.length, slice.length);
    return PagedMediaResult(items: slice, total: total);
  }

  Future<List<MediaItem>> _listMediaSaf(
    FolderHandle folder, {
    void Function(int processed, int total)? onProgress,
  }) async {
    // ✅ 直下のみ
    final entries = await _safListShallow(folder.raw);

    final folders = <MediaItem>[];
    final files = <MediaItem>[];

    int processed = 0;
    final total = entries.length;

    for (final e in entries) {
      if (e.isDir) {
        folders.add(
          MediaItem(
            id: e.documentUri,          // サブフォルダURI
            displayName: e.name,
            kind: MediaKind.folder,
            folderRaw: folder.raw,
            modified: e.modified,
            tags: const [],
          ),
        );
      } else {
        final ext = _lowerExt(e.name);

        MediaKind? kind;
        if (ext == _pdfExt) kind = MediaKind.pdf;
        if (_imageExt.contains(ext)) kind = MediaKind.image;
        if (kind == null) continue;

        files.add(
          MediaItem(
            id: e.documentUri,
            displayName: e.name,
            kind: kind,
            folderRaw: folder.raw,
            modified: e.modified,
            tags: const [],
          ),
        );
      }

      processed++;
      if (onProgress != null) onProgress(processed, total);
    }

    // フォルダ→ファイル順が見やすい
    return <MediaItem>[...folders, ...files];
  }
  
  Future<int> _safCountMedia(String treeUri) async {
    return _docmanSync(() async {
      int total = 0;

      final root = await DocumentFile.fromUri(treeUri);
      if (root == null || root.isDirectory != true) return 0;

      final queue = <String>[root.uri];

      while (queue.isNotEmpty) {
        final dirUri = queue.removeLast();
        final dir = await DocumentFile.fromUri(dirUri);
        if (dir == null || dir.isDirectory != true) continue;

        List<DocumentFile> children;
        try {
          children = await dir.listDocuments();
        } catch (_) {
          continue;
        }

        for (final f in children) {
          final name = (f.name ?? '').trim();
          if (name.isEmpty) continue;

          if (f.isDirectory == true) {
            if (f.uri.isNotEmpty) queue.add(f.uri);
          } else {
            final ext = _lowerExt(name);
            if (ext == _pdfExt || _imageExt.contains(ext)) total++;
          }
        }

        await Future<void>.delayed(Duration.zero);
      }

      return total;
    });
  }

  Future<List<MediaItem>> _listMediaFs(
    FolderHandle folder, {
    void Function(int processed, int total)? onProgress,
  }) async {
    final dir = Directory(folder.raw);
    if (!await dir.exists()) return const [];
  
    bool isTarget(FileSystemEntity e) {
      if (e is! File) return false;
      final name = e.uri.pathSegments.isNotEmpty ? e.uri.pathSegments.last : e.path;
      final ext = _lowerExt(name);
      return ext == _pdfExt || _imageExt.contains(ext);
    }
  
    // total が必要なら 2パス（%を出すため）
    int total = 0;
    if (onProgress != null) {
      await for (final ent in dir.list(recursive: false, followLinks: false)) {
        if (isTarget(ent)) total++;
      }
    }
  
    final items = <MediaItem>[];
    int processed = 0;
  
    await for (final ent in dir.list(recursive: false, followLinks: false)) {
      if (ent is! File) continue;
  
      final name = ent.uri.pathSegments.isNotEmpty
          ? ent.uri.pathSegments.last
          : ent.path;
  
      final ext = _lowerExt(name);
  
      MediaKind? kind;
      if (ext == _pdfExt) {
        kind = MediaKind.pdf;
      } else if (_imageExt.contains(ext)) {
        kind = MediaKind.image;
      }
      if (kind == null) continue;
  
      final stat = await ent.stat();
      items.add(
        MediaItem(
          id: ent.path,
          displayName: name,
          kind: kind,
          folderRaw: folder.raw,
          modified: stat.modified,
          tags: const [],
        ),
      );
  
      processed++;
      if (onProgress != null) onProgress(processed, total);
    }
  
    return items;
  }

  @override
  Future<List<MediaItem>> listMediaRecursiveFiles(
    FolderHandle folder, {
    void Function(int processed, int total)? onProgress,
  }) async {
    final raw = folder.raw;
    if (raw.startsWith('content://')) {
      return _listMediaSafRecursiveFiles(folder, onProgress: onProgress);
    } else {
      return _listMediaFsRecursiveFiles(folder, onProgress: onProgress);
    }
  }

  Future<List<MediaItem>> _listMediaSafRecursiveFiles(
    FolderHandle folder, {
    void Function(int processed, int total)? onProgress,
  }) async {
    // total（進捗%用）を先に数える。重いので onProgress がある時だけ。
    final total = (onProgress == null) ? 0 : await _docmanSync(() => _safCountMedia(folder.raw));

    final entries = await _docmanSync(() => _safListRecursive(
          folder.raw,
          onProgress: onProgress,
          total: total,
        ));

    // entries はファイルのみ入る設計なので MediaItem にする
    final items = <MediaItem>[];
    for (final e in entries) {
      final ext = _lowerExt(e.name);
      MediaKind? kind;
      if (ext == _pdfExt) kind = MediaKind.pdf;
      if (_imageExt.contains(ext)) kind = MediaKind.image;
      if (kind == null) continue;

      items.add(MediaItem(
        id: e.documentUri,
        displayName: e.name,
        kind: kind,
        folderRaw: folder.raw, // ★ “検索元の登録フォルダ” を root として保持
        modified: e.modified,
        tags: const [],
      ));
    }
    return items;
  }

  Future<List<MediaItem>> _listMediaFsRecursiveFiles(
    FolderHandle folder, {
    void Function(int processed, int total)? onProgress,
  }) async {
    final dir = Directory(folder.raw);
    if (!await dir.exists()) return const [];
  
    bool isTarget(FileSystemEntity e) {
      if (e is! File) return false;
      final name = e.uri.pathSegments.isNotEmpty ? e.uri.pathSegments.last : e.path;
      final ext = _lowerExt(name);
      return ext == _pdfExt || _imageExt.contains(ext);
    }
  
    int total = 0;
    if (onProgress != null) {
      await for (final ent in dir.list(recursive: true, followLinks: false)) {
        if (isTarget(ent)) total++;
      }
    }
  
    final items = <MediaItem>[];
    int processed = 0;
  
    await for (final ent in dir.list(recursive: true, followLinks: false)) {
      if (ent is! File) continue;
  
      final name = ent.uri.pathSegments.isNotEmpty ? ent.uri.pathSegments.last : ent.path;
      final ext = _lowerExt(name);
  
      MediaKind? kind;
      if (ext == _pdfExt) kind = MediaKind.pdf;
      if (_imageExt.contains(ext)) kind = MediaKind.image;
      if (kind == null) continue;
  
      final stat = await ent.stat();
      items.add(MediaItem(
        id: ent.path,
        displayName: name,
        kind: kind,
        folderRaw: folder.raw, // ★ root
        modified: stat.modified,
        tags: const [],
      ));
  
      processed++;
      if (onProgress != null) onProgress(processed, total);
    }
  
    return items;
  }

  @override
  Future<Uint8List> readBytes(MediaItem item) {
    if (item.id.startsWith('content://')) {
      return _safReadBytes(item.id);
    }
    return File(item.id).readAsBytes();
  }

  @override
  Future<int> getPageCount(MediaItem item) async {
    if (item.kind != MediaKind.pdf) return 1;
    final doc = await _openPdf(item.id);
    return doc.pagesCount;
  }

  @override
  Future<Uint8List> renderPageBytes(
    MediaItem item,
    int page, {
    int maxWidth = 1600,
  }) async {
    if (item.kind != MediaKind.pdf) {
      final bytes = await readBytes(item);
      if (_lowerExt(item.displayName) == '.avif' || _lowerExt(item.id) == '.avif') {
        try {
          return await _makeImageThumb(bytes, maxWidth);
        } catch (_) {
          return bytes;
        }
      }
      return bytes;
    }
    final doc = await _openPdf(item.id);
    final total = doc.pagesCount;
    final p = page.clamp(1, total);
    return _renderPage(item.id, doc, p, maxWidth);
  }

  @override
  Future<ThumbPair> readThumbPair(MediaItem item, {int maxWidth = 360}) async {
    final cacheKey = '${item.id}|$maxWidth';

    // 1) メモリキャッシュ
    final cached = _thumbCache.get(cacheKey);
    if (cached != null) return cached;

    // 2) 同一キーの同時実行まとめ
    final inflight = _thumbInFlight[cacheKey];
    if (inflight != null) return inflight;

    final future = () async {
      await _acquireThumbSlot(2); // ここは後で 1 に落とす
      try {
        // 3) ディスクキャッシュ
        try {
          final f = await _thumbDiskFile(cacheKey);
          if (await f.exists()) {
            final bytes = await f.readAsBytes();
            if (bytes.isNotEmpty) {
              final pair = ThumbPair(front: bytes, back: null);
              _thumbCache.put(cacheKey, pair);
              return pair;
            }
          }
        } catch (_) {
          // ディスクキャッシュ失敗は無視して生成へ
        }

        // 4) 生成
        final pair = await _buildThumbPair(item, maxWidth);

        // 5) 保存（失敗してもOK）
        _thumbCache.put(cacheKey, pair);
        try {
          final f = await _thumbDiskFile(cacheKey);
          await f.writeAsBytes(pair.front, flush: false);
        } catch (_) {}

        return pair;
      } finally {
        _releaseThumbSlot();
        _thumbInFlight.remove(cacheKey);
      }
    }();

    _thumbInFlight[cacheKey] = future;
    return future;
  }

  Future<ThumbPair> _buildThumbPair(MediaItem item, int maxWidth) async {
    if (item.kind == MediaKind.image) {
      final bytes = await readBytes(item);
      final thumb = await _makeImageThumb(bytes, maxWidth);
      return ThumbPair(front: thumb, back: null);
    }

    final doc = await _openPdf(item.id);
    final pageCount = doc.pagesCount;
    final mid = (pageCount / 2).ceil().clamp(1, pageCount);

    final front = await _renderPage(item.id, doc, 1, maxWidth);
    return ThumbPair(front: front, back: null);
  }

  Future<PdfDocument> _openPdf(String documentUri) {
    return _lockOf(documentUri).synchronized(() async {
      final cached = _pdfCache.remove(documentUri);
      if (cached != null) {
        _pdfCache[documentUri] = cached;
        return cached;
      }

      PdfDocument doc;

      if (documentUri.startsWith('content://')) {
        doc = await _docmanSync(() async {
          final docFile = await DocumentFile.fromUri(documentUri);
          if (docFile == null) throw Exception('DocumentFile.fromUri failed: $documentUri');

          final cachedFile = await docFile.cache();
          if (cachedFile == null) throw Exception('cache() failed: $documentUri');

          return PdfDocument.openFile(cachedFile.path);
        });
      } else {
        final f = File(documentUri);
        if (!await f.exists()) throw Exception('PDF file not found: $documentUri');
        doc = await PdfDocument.openFile(documentUri);
      }

      _pdfCache[documentUri] = doc;
      while (_pdfCache.length > _pdfCacheMaxEntries) {
        final oldestKey = _pdfCache.keys.first;
        final oldest = _pdfCache.remove(oldestKey);
        if (oldest != null) await oldest.close();
      }
      return doc;
    });
  }

  Future<Uint8List> _renderPage(
    String documentUri,
    PdfDocument doc,
    int pageNumber,
    int maxWidth,
  ) {
    return _lockOf(documentUri).synchronized(() async {
      final page = await doc.getPage(pageNumber);

      final scale = maxWidth / page.width;
      final double w = maxWidth.toDouble();
      final double h = (page.height * scale);

      final img = await page.render(
        width: w,
        height: h,
        format: PdfPageImageFormat.png,
      );

      await page.close();

      if (img == null) throw Exception('PDF render failed (page=$pageNumber)');
      return img.bytes;
    });
  }

  Future<void> dispose() async {
    _thumbInFlight.clear();
    _thumbCache.clear();

    for (final doc in _pdfCache.values) {
      await doc.close();
    }
    _pdfCache.clear();
  }

  static String _lowerExt(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return '';
    return name.substring(dot).toLowerCase();
  }

  static String _fileName(String path) {
    if (path.startsWith('content://')) return path;
    var p = path.replaceAll('\\', '/');
    final idx = p.lastIndexOf('/');
    return idx < 0 ? p : p.substring(idx + 1);
  }

  bool _isTargetFileName(String name) {
    final ext = _lowerExt(name);
    return ext == _pdfExt || _imageExt.contains(ext);
  }

  String? _pickedDocIdentifier(dynamic picked) {
    try {
      final uri = picked.uri?.toString();
      if (uri is String && uri.isNotEmpty) return uri;
    } catch (_) {}
    try {
      final uri = picked.uri;
      if (uri is String && uri.isNotEmpty) return uri;
    } catch (_) {}
    try {
      final path = picked.path?.toString();
      if (path is String && path.isNotEmpty) return path;
    } catch (_) {}
    return null;
  }

  Future<MediaItem?> _externalItemFromRaw(String raw) async {
    if (raw.trim().isEmpty) return null;
    if (raw.startsWith('content://')) {
      return _externalItemFromContentUri(raw);
    }
    if (raw.startsWith('file://')) {
      return _externalItemFromFilePath(Uri.parse(raw).toFilePath());
    }
    return _externalItemFromFilePath(raw);
  }

  Future<MediaItem?> _externalItemFromContentUri(String uri) async {
    return _docmanSync(() async {
      final doc = await DocumentFile.fromUri(uri);
      if (doc == null || doc.isDirectory == true) return null;

      final rawName = (doc.name ?? '').trim();
      final name = rawName.isNotEmpty ? rawName : _fileName(uri);
      if (!_isTargetFileName(name)) return null;

      final ext = _lowerExt(name);
      return MediaItem(
        id: uri,
        displayName: name,
        kind: ext == _pdfExt ? MediaKind.pdf : MediaKind.image,
        folderRaw: uri,
        modified: _toDateTimeSafe(doc.lastModified),
        tags: const [],
      );
    });
  }

  Future<MediaItem?> _externalItemFromFilePath(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;

    final name = _fileName(path);
    if (!_isTargetFileName(name)) return null;

    final stat = await file.stat();
    final ext = _lowerExt(name);
    return MediaItem(
      id: path,
      displayName: name,
      kind: ext == _pdfExt ? MediaKind.pdf : MediaKind.image,
      folderRaw: file.parent.path,
      modified: stat.modified,
      tags: const [],
    );
  }

  @override
  Future<MediaItem> rename(MediaItem item, String newDisplayName) async {
    if (item.kind != MediaKind.pdf) {
      throw Exception('rename: only pdf is supported now');
    }

    return _docmanSync(() async {
      final src = await DocumentFile.fromUri(item.id);
      if (src == null) throw Exception('rename: src not found: ${item.id}');

      final dir = await DocumentFile.fromUri(item.folderRaw);
      if (dir == null || dir.isDirectory != true) {
        throw Exception('rename: parent dir not found: ${item.folderRaw}');
      }

      final fixedName = _ensurePdfName(newDisplayName);
      final d = src as dynamic;

      DocumentFile? moved;

      try {
        final r = await d.moveTo(dir, newName: fixedName);
        if (r is DocumentFile) moved = r;
      } catch (_) {}

      if (moved == null) {
        try {
          final r = await d.moveTo(dir, name: fixedName);
          if (r is DocumentFile) moved = r;
        } catch (_) {}
      }

      if (moved == null) {
        try {
          final r = await d.moveTo(dir: dir, newName: fixedName);
          if (r is DocumentFile) moved = r;
        } catch (_) {}
      }

      if (moved == null) {
        throw Exception('rename: moveTo not supported or permission denied');
      }

      // キャッシュ無効化
      _invalidateSafShallow(item.folderRaw);
      await _invalidateFolderIndex(item.folderRaw);

      return MediaItem(
        id: moved.uri,
        displayName: fixedName,
        kind: item.kind,
        folderRaw: item.folderRaw,
        modified: DateTime.now(),
        tags: item.tags,
      );
    });
  }

  String _ensurePdfName(String name) {
    final n = name.trim();
    if (n.isEmpty) return 'export.pdf';
    return n.toLowerCase().endsWith('.pdf') ? n : '$n.pdf';
  }

 Future<List<_SafEntry>> _safListRecursive(
    String treeUri, {
    void Function(int processed, int total)? onProgress,
    required int total,
  }) async {
    return _docmanSync(() async {
      final root = await DocumentFile.fromUri(treeUri);
      if (root == null || root.isDirectory != true) return const [];

      final out = <_SafEntry>[];
      final queue = <String>[root.uri];
      int processed = 0;

      while (queue.isNotEmpty) {
        final dirUri = queue.removeLast();
        final dir = await DocumentFile.fromUri(dirUri);
        if (dir == null || dir.isDirectory != true) continue;

        List<DocumentFile> children;
        try {
          children = await dir.listDocuments();
        } catch (_) {
          continue;
        }

        for (final f in children) {
          final name = (f.name ?? '').trim();
          if (name.isEmpty) continue;

          final isDir = f.isDirectory == true;
          if (isDir) {
            if (f.uri.isNotEmpty) queue.add(f.uri);
            continue;
          }

          final ext = _lowerExt(name);
          if (!(ext == _pdfExt || _imageExt.contains(ext))) continue;

          out.add(_SafEntry(
            documentUri: f.uri,
            name: name,
            modified: _toDateTimeSafe(f.lastModified),
            isDir: false,
          ));

          processed++;
          if (onProgress != null) onProgress(processed, total);
        }

        await Future<void>.delayed(Duration.zero);
      }

      return out;
    });
  }

  @override
  Future<int> importIntoFolder(
    FolderHandle folder, {
    ImportRequest? request,
    void Function(MediaTransferProgress progress)? onProgress,
  }) async {
    final sourceKind = request?.sourceKind ?? ImportSourceKind.files;
    if (sourceKind == ImportSourceKind.folder) {
      final pickedFolder = await pickFolder();
      if (pickedFolder == null) {
        return 0;
      }
      final items = await listMediaRecursiveFiles(pickedFolder);
      return importItemsIntoFolder(
        folder,
        items,
        importMetadata: request?.metadata,
        skipIfExists: request?.skipIfExists ?? true,
        onProgress: onProgress,
      );
    }

    final picked = await DocMan.pick.files(
      extensions: MediaFileTypes.mediaPickerExtensions,
      limit: 200,
    );
      if (picked.isEmpty) return 0;

      // 1) まずターゲットが「保管庫など file path」なら確実に書ける
      if (!folder.raw.startsWith('content://')) {
        final dir = Directory(folder.raw);
        if (!await dir.exists()) await dir.create(recursive: true);

        int ok = 0;
        for (final f in picked) {
          try {
            final name = f.path.split('/').last;
            final bytes = await f.readAsBytes();
            if (bytes.isEmpty) continue;

            final outPath = await _uniquePathInDir(dir, name);
            await File(outPath).writeAsBytes(bytes, flush: true);
            ok++;
          } catch (_) {}
        }
        return ok;
      }

      // 2) SAFフォルダの場合：書き込み可なら直接入れる
    return _docmanSync(() async {
      final dir = await DocumentFile.fromUri(folder.raw);
      if (dir == null) throw Exception('DocumentFile.fromUri failed: ${folder.raw}');
      if (dir.isDirectory != true) throw Exception('Target is not a directory: ${folder.raw}');

      if (dir.canCreate == true) {
        int ok = 0;
        for (final f in picked) {
          try {
            final name = f.path.split('/').last;
            final bytes = await f.readAsBytes();
            if (bytes.isEmpty) continue;

            final unique = await _uniqueName(dir, name); // ←これも docman 操作
            final created = await _createFile(dir, unique, bytes);
            if (created != null) ok++;
          } catch (_) {}
        }
        _invalidateSafShallow(folder.raw);
        await _invalidateFolderIndex(folder.raw);
        return ok;
    }

    // 3) SAFが書き込み不可 → ★保管庫へ確実に取り込む（fallback）
      final lib = await getAppLibraryFolder();
      final libDir = Directory(lib.raw);
      if (!await libDir.exists()) await libDir.create(recursive: true);

      int ok = 0;
      for (final f in picked) {
        try {
          final name = f.path.split('/').last;
          final bytes = await f.readAsBytes();
          if (bytes.isEmpty) continue;

          final outPath = await _uniquePathInDir(libDir, name);
          await File(outPath).writeAsBytes(bytes, flush: true);
          ok++;
        } catch (_) {}
      }
      return ok;
    });
  }

  @override
  Future<UrlImportResult> importFromUrlIntoFolder(
    FolderHandle folder,
    String sourceUrl, {
    ImportMetadata? importMetadata,
    UrlImportOptions? options,
    void Function(MediaTransferProgress progress)? onProgress,
  }) async {
    throw UnsupportedError('URL import is not supported on Android');
  }

  @override
  Future<int> importItemsIntoFolder(
    FolderHandle dest,
    List<MediaItem> items, {
    ImportMetadata? importMetadata,
    bool skipIfExists = true,
    void Function(MediaTransferProgress progress)? onProgress,
  }) async {
    // 1) dest が file path（保管庫は通常これ）なら、Directoryへ書き込む
    if (!dest.raw.startsWith('content://')) {
      final dir = Directory(dest.raw);
      if (!await dir.exists()) await dir.create(recursive: true);

      final existingLowerNames = <String>{};
      await for (final ent in dir.list(recursive: false, followLinks: false)) {
        if (ent is File) {
          final name = ent.uri.pathSegments.isNotEmpty
              ? ent.uri.pathSegments.last
              : ent.path;
          existingLowerNames.add(name.toLowerCase());
        }
      }

      int ok = 0;
      for (final it in items) {
        if (it.kind == MediaKind.folder) continue;

        final lower = it.displayName.toLowerCase();
        if (skipIfExists && existingLowerNames.contains(lower)) continue;

        try {
          final bytes = await readBytes(it); // 既存の repo API を利用
          if (bytes.isEmpty) continue;

          final outPath = skipIfExists
              ? '${dir.path}/${it.displayName}'
              : await _uniquePathInDir(dir, it.displayName);

          // skipIfExists=true でも、並行で同名が出来る等の事故を避けたいので存在確認
          if (skipIfExists && await File(outPath).exists()) continue;

          await File(outPath).writeAsBytes(bytes, flush: true);
          existingLowerNames.add((outPath.split('/').last).toLowerCase());
          ok++;
        } catch (_) {}
      }
      return ok;
    }

    // 2) dest が SAF の場合（必要なら）
    return _docmanSync(() async {
      final dir = await DocumentFile.fromUri(dest.raw);
      if (dir == null) throw Exception('DocumentFile.fromUri failed: ${dest.raw}');
      if (dir.isDirectory != true) throw Exception('Target is not a directory: ${dest.raw}');
      if (dir.canCreate != true) throw Exception('Target folder is not writable: ${dest.raw}');

      // 既存名セット（docmanで浅く取得）
      final existingLowerNames = <String>{};
      final children = await dir.listDocuments();
      for (final c in children) {
        final n = (c.name ?? '').trim();
        if (n.isNotEmpty) existingLowerNames.add(n.toLowerCase());
      }

      int ok = 0;
      for (final it in items) {
        if (it.kind == MediaKind.folder) continue;

        final lower = it.displayName.toLowerCase();
        if (skipIfExists && existingLowerNames.contains(lower)) continue;

        try {
          final bytes = await readBytes(it);
          if (bytes.isEmpty) continue;

          final uniqueName = skipIfExists
              ? it.displayName
              : await _uniqueName(dir, it.displayName);

          if (skipIfExists && existingLowerNames.contains(uniqueName.toLowerCase())) continue;

          final created = await _createFile(dir, uniqueName, bytes);
          if (created != null) {
            existingLowerNames.add(uniqueName.toLowerCase());
            ok++;
          }
        } catch (_) {}
      }

      _invalidateSafShallow(dest.raw);
      await _invalidateFolderIndex(dest.raw);
      return ok;
    });
  }

  Future<String> _uniquePathInDir(Directory dir, String name) async {
    final dot = name.lastIndexOf('.');
    final base = dot >= 0 ? name.substring(0, dot) : name;
    final ext = dot >= 0 ? name.substring(dot) : '';

    String candidate = name;
    int n = 1;
    while (await File('${dir.path}/$candidate').exists()) {
      candidate = '$base ($n)$ext';
      n++;
      if (n > 999) {
        return '${dir.path}/${base}_${DateTime.now().millisecondsSinceEpoch}$ext';
      }
    }
    return '${dir.path}/$candidate';
  }

  Future<String> _uniqueName(DocumentFile dir, String name) async {
    final dot = name.lastIndexOf('.');
    final base = dot >= 0 ? name.substring(0, dot) : name;
    final ext = dot >= 0 ? name.substring(dot) : '';

    String candidate = name;
    int n = 1;
    while (true) {
      final found = await dir.find(candidate);
      if (found == null || found.exists != true) return candidate;
      candidate = '$base ($n)$ext';
      n++;
      if (n > 999)
        return '${base}_${DateTime.now().millisecondsSinceEpoch}$ext';
    }
  }

  // -------------------------
  // docman の createFile/delete シグネチャ差を吸収
  // -------------------------
  Future<DocumentFile?> _createFile(
    DocumentFile dir,
    String name,
    Uint8List bytes,
  ) async {
    final d = dir as dynamic;

    // パターン1: createFile(name: ..., bytes: ...)
    try {
      final r = await d.createFile(name: name, bytes: bytes);
      if (r is DocumentFile) return r;
    } catch (_) {}

    // パターン2: createFile(name, bytes)
    try {
      final r = await d.createFile(name, bytes);
      if (r is DocumentFile) return r;
    } catch (_) {}

    // パターン3: createFile(name: ..., mimeType: ..., bytes: ...)
    try {
      final mime = _mimeFor(itemExt: _lowerExt(name));
      final r = await d.createFile(name: name, mimeType: mime, bytes: bytes);
      if (r is DocumentFile) return r;
    } catch (_) {}

    return null;
  }

  
  Future<bool> _deleteDoc(DocumentFile doc) async {
    final d = doc as dynamic;
    // パターン1: delete()
    try {
      final r = await d.delete();
      if (r is bool) return r;
      return true; // void の場合も成功扱い
    } catch (_) {}
    // パターン2: delete(recursive: false)
    try {
      final r = await d.delete(recursive: false);
      if (r is bool) return r;
      return true;
    } catch (_) {}
    // パターン3: deleteFile()
    try {
      final r = await d.deleteFile();
      if (r is bool) return r;
      return true;
    } catch (_) {}
    return false;
  }

    bool _isFsFolderInLibrary(MediaItem item) {
    return item.kind == MediaKind.folder && !item.id.startsWith('content://');
  }

  @override
  Future<bool> deleteItem(MediaItem item) async {
    // SAFの外部フォルダ削除は今回は未対応
    if (item.kind == MediaKind.folder && item.id.startsWith('content://')) {
      return false;
    }

    // アプリ保管庫の通常フォルダ削除
    if (_isFsFolderInLibrary(item)) {
      try {
        final dir = Directory(item.id);
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }

        _thumbCache.clear();
        _invalidateSafShallowAll();
        await _invalidateFolderIndex(item.folderRaw);
        return true;
      } catch (_) {
        return false;
      }
    }

    // SAF (content://) の画像/PDF
    if (item.id.startsWith('content://')) {
      return _docmanSync(() async {
        final doc = await DocumentFile.fromUri(item.id);
        if (doc == null) return false;

        final ok = await _deleteDoc(doc);

        _invalidateSafShallow(item.folderRaw);
        await _invalidateFolderIndex(item.folderRaw);

        return ok;
      });
    }

    // 通常ファイル（保管庫など）
    try {
      final f = File(item.id);
      if (await f.exists()) {
        await f.delete();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<int> deleteItems(List<MediaItem> items) async {
    int ok = 0;
    for (final item in items) {
      final deleted = await deleteItem(item);
      if (deleted) ok++;
    }
    return ok;
  }

  String _mimeFor({required String itemExt}) {
    if (itemExt == '.pdf') return 'application/pdf';
    return MediaFileTypes.imageMimeTypeForFileName(itemExt);
  }

  Future<_ShallowCacheEntry> _getSafShallowCached(String dirUri) async {
    // TTL内なら返す
    final hit = _safShallowCache[dirUri];
    if (hit != null && DateTime.now().difference(hit.at) <= _safShallowTtl) {
      return hit;
    }

    // 直下一覧を取り直す（docman listDocumentsはここだけ）
    final entries = await _safListShallow(dirUri);

    // ここで “一度だけ” 分類＆ソート
    final dirs = <_SafEntry>[];
    final files = <_SafEntry>[];

    for (final e in entries) {
      if (e.isDir) {
        dirs.add(e);
      } else {
        if (_isTargetFileName(e.name)) files.add(e);
      }
    }

    int cmp(_SafEntry a, _SafEntry b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase());

    dirs.sort(cmp);
    files.sort(cmp);

    final sortedAll = <_SafEntry>[...dirs, ...files];

    final entry = _ShallowCacheEntry(
      at: DateTime.now(),
      entries: entries,
      sortedAll: sortedAll,
    );

    _safShallowCache[dirUri] = entry;
    return entry;
  }

  void _invalidateSafShallow(String dirUri) {
    _safShallowCache.remove(dirUri);
  }

  void _invalidateSafShallowAll() {
    _safShallowCache.clear();
  }
}

class _SafEntry {
  final String documentUri;
  final String name;
  final DateTime? modified;
  final bool isDir;
  _SafEntry({
    required this.documentUri,
    required this.name,
    required this.modified,
    required this.isDir,
  });
}




class _LruCache<K, V> {
  final int maxBytes;
  final int maxEntries;
  final int Function(V value) sizeOf;

  final LinkedHashMap<K, V> _map = LinkedHashMap<K, V>();
  int _bytes = 0;

  _LruCache({
    required this.maxBytes,
    required this.maxEntries,
    required this.sizeOf,
  });

  V? get(K key) {
    final v = _map.remove(key);
    if (v == null) return null;
    _map[key] = v;
    return v;
  }

  void put(K key, V value) {
    final old = _map.remove(key);
    if (old != null) _bytes -= sizeOf(old);

    _map[key] = value;
    _bytes += sizeOf(value);
    _evictIfNeeded();
  }

  void _evictIfNeeded() {
    while (_map.isNotEmpty && (_map.length > maxEntries || _bytes > maxBytes)) {
      final oldestKey = _map.keys.first;
      final oldestVal = _map.remove(oldestKey)!;
      _bytes -= sizeOf(oldestVal);
    }
  }

  void clear() {
    _map.clear();
    _bytes = 0;
  }
}

Future<Uint8List> _makeImageThumb(Uint8List src, int targetWidth) async {
  if (src.isEmpty) return src;
  final codec = await ui.instantiateImageCodec(src, targetWidth: targetWidth);
  final frame = await codec.getNextFrame();
  final ui.Image image = frame.image;

  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  if (byteData == null) return src;

  return byteData.buffer.asUint8List();
}

class _AsyncMutex {
  Future<void> _last = Future.value();

  Future<T> synchronized<T>(Future<T> Function() action) {
    final completer = Completer<T>();

    _last = _last.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });

    return completer.future;
  }
}

// ==============================
// SAF shallow cache（直下一覧/ソート済み）
// ==============================

class _ShallowCacheEntry {
  final DateTime at;
  final List<_SafEntry> entries;         // raw listDocuments結果（整形済み）
  final List<_SafEntry> sortedAll;       // dirs→files + name sort 済み
  _ShallowCacheEntry({
    required this.at,
    required this.entries,
    required this.sortedAll,
  });
}
