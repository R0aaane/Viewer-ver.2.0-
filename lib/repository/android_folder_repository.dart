import 'dart:async';
import 'dart:io';
import 'dart:collection';
import 'dart:ui' as ui;
import 'dart:convert';

import 'package:docman/docman.dart';
import 'package:flutter/foundation.dart';
import 'package:pdfx/pdfx.dart';
import 'package:path_provider/path_provider.dart';
import 'package:drift/drift.dart' as drift;

import '../media_file_types.dart';
import '../models/folder.dart';
import '../models/mediaItem.dart';
import '../models/metadata_settings.dart';
import '../services/app_settings_service.dart';
import '../services/item_name_service.dart';
import '../services/import_source_normalizer.dart';
import '../services/local_path_operation_service.dart';
import '../services/url_import_downloader_service.dart';
import 'mediaRepository.dart';

import '../database/app_db.dart' as db;

class AndroidFolderRepository implements MediaRepository {
  final db.AppDb _db;
  final UrlImportDownloaderService _urlImportDownloader =
      UrlImportDownloaderService();
  final AppSettingsService _settingsService = AppSettingsService();
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
  bool get canImportFromUrl => true;

  @override
  Future<void> reloadSettings() async {}

  @override
  Future<List<FolderHandle>> listAvailableFolders() async =>
      const <FolderHandle>[];

  // Folder index cache TTL.
  static const Duration _folderIndexTtl = Duration(minutes: 10);

  // Supported image extensions for local filesystem scans.
  static const Set<String> _imageExt = MediaFileTypes.imageExtensions;
  static const _pdfExt = '.pdf';
  static const _epubExt = '.epub';
  static const Duration _safShallowTtl = Duration(seconds: 15);

  final _AsyncMutex _docmanMutex = _AsyncMutex();

  Future<T> _docmanSync<T>(Future<T> Function() action) {
    return _docmanMutex.synchronized(action);
  }

  // SAF shallow cache keyed by directory URI.
  final Map<String, _ShallowCacheEntry> _safShallowCache = {};

  final _LruCache<String, ThumbPair> _thumbCache = _LruCache<String, ThumbPair>(
    maxBytes: 64 * 1024 * 1024,
    maxEntries: 400,
    sizeOf: (pair) =>
        pair.front.lengthInBytes + (pair.back?.lengthInBytes ?? 0),
  );

  // Small in-memory PDF document cache.
  final Map<String, _AsyncMutex> _pdfLocks = {};
  _AsyncMutex _lockOf(String uri) =>
      _pdfLocks.putIfAbsent(uri, () => _AsyncMutex());

  final Map<String, Future<ThumbPair>> _thumbInFlight = {};

  final LinkedHashMap<String, PdfDocument> _pdfCache = LinkedHashMap();
  static const int _pdfCacheMaxEntries = 6;

  final Map<String, Future<void>> _folderIndexInFlight = {};

  // Limit concurrent thumbnail generation work.
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

  int _thumbConcurrencyFor(MediaItem item) {
    if (item.kind == MediaKind.image && item.id.startsWith('content://')) {
      return 1;
    }
    return 2;
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
      case db.FolderEntryKindDb.epub:
        return MediaKind.epub;
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
      case MediaKind.epub:
        return db.FolderEntryKindDb.epub.index;
    }
  }

  String _sortKey(String name) => name.trim().toLowerCase();

  Future<db.DbFolderIndex?> _getFolderIndexRow(String folderRaw) {
    return (_db.select(
      _db.folderIndexes,
    )..where((t) => t.folderRaw.equals(folderRaw))).getSingleOrNull();
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
        (t) =>
            drift.OrderingTerm.asc(t.kind), // folder(0) -> image(1) -> pdf(2)
        (t) => drift.OrderingTerm.asc(t.sortName), // name sort
      ])
      ..limit(limit, offset: offset);

    final rows = await q.get();

    final items = rows
        .map((r) {
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
        })
        .toList(growable: false);

    return PagedMediaResult(items: items, total: idx.totalCount);
  }

  /// Rebuild the folder index for a SAF directory.
  Future<void> _rebuildFolderIndexSaf(String folderRaw) async {
    // Read the current direct children from SAF.
    final entries = (await _getSafShallowCached(folderRaw)).entries;

    // Convert SAF entries into cached DB rows.
    final out = <db.FolderEntriesCompanion>[];
    for (final e in entries) {
      if (e.isDir) {
        out.add(
          db.FolderEntriesCompanion.insert(
            folderRaw: folderRaw,
            entryId: e.documentUri,
            displayName: e.name,
            kind: _mediaKindToFolderEntryKind(MediaKind.folder),
            modifiedEpochMs: drift.Value(e.modified?.millisecondsSinceEpoch),
            sortName: _sortKey(e.name),
          ),
        );
        continue;
      }

      final ext = _lowerExt(e.name);
      final kind = _mediaKindForExt(ext);
      if (kind != null) {
        out.add(
          db.FolderEntriesCompanion.insert(
            folderRaw: folderRaw,
            entryId: e.documentUri,
            displayName: e.name,
            kind: _mediaKindToFolderEntryKind(kind),
            modifiedEpochMs: drift.Value(e.modified?.millisecondsSinceEpoch),
            sortName: _sortKey(e.name),
          ),
        );
        continue;
      }
    }

    // Keep folder-first ordering and stable total counts in sync with the DB page order.
    out.sort((a, b) {
      final ak = a.kind.value;
      final bk = b.kind.value;
      if (ak != bk) return ak.compareTo(bk);
      return a.sortName.value.compareTo(b.sortName.value);
    });

    final total = out.length;
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    await _db.transaction(() async {
      // Replace cached folder rows before inserting the fresh snapshot.
      await (_db.delete(
        _db.folderEntries,
      )..where((t) => t.folderRaw.equals(folderRaw))).go();

      await _db
          .into(_db.folderIndexes)
          .insertOnConflictUpdate(
            db.FolderIndexesCompanion.insert(
              folderRaw: folderRaw,
              scannedAtEpochMs: nowMs,
              totalCount: total,
            ),
          );

      if (out.isNotEmpty) {
        await _db.batch((b) {
          b.insertAll(
            _db.folderEntries,
            out,
            mode: drift.InsertMode.insertOrReplace,
          );
        });
      }
    });
  }

  Future<void> _ensureFolderIndexSaf(
    String folderRaw, {
    bool force = false,
  }) async {
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
      await (_db.delete(
        _db.folderEntries,
      )..where((t) => t.folderRaw.equals(folderRaw))).go();
      await (_db.delete(
        _db.folderIndexes,
      )..where((t) => t.folderRaw.equals(folderRaw))).go();
    });
  }

  // Thumbnail disk cache.
  Directory? _thumbDiskDir;

  Future<Directory> _ensureThumbDiskDir() async {
    if (_thumbDiskDir != null) return _thumbDiskDir!;
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/thumbs_v1');
    if (!await dir.exists()) await dir.create(recursive: true);
    _thumbDiskDir = dir;
    return dir;
  }

  // Stable FNV-1a 64-bit hash used for cache keys.
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
    return File('${dir.path}/$name.bin');
  }

  // ==============================
  // SAF helpers backed by docman.

  Future<String?> _safPickTreeUri() async {
    final dir = await DocMan.pick.directory();
    return dir?.uri;
  }

  DateTime? _toDateTimeSafe(Object? lm) {
    // docman/provider modified time may be int, int?, or null.
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

      String fallbackNameFromUri(String uri) {
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
        final rawName = f.name.trim();
        final isDir = f.isDirectory == true;

        final name = rawName.isNotEmpty
            ? rawName
            : (isDir ? fallbackNameFromUri(f.uri) : '');
        if (name.isEmpty) continue;

        out.add(
          _SafEntry(
            documentUri: f.uri,
            name: name,
            modified: null,
            isDir: isDir,
          ),
        );
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

  Future<String> _cachedFilePathForContentUri(String documentUri) async {
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
      return cached.path;
    });
  }

  // ==============================
  // MediaRepository
  // ==============================

  @override
  Future<FolderHandle> getAppLibraryFolder() async {
    final settings = await _settingsService.loadMetadataSettings();
    final configuredPath = settings.hostLibraryPath.trim();
    final libraryPath = configuredPath.isNotEmpty
        ? configuredPath
        : '${(await getApplicationDocumentsDirectory()).path}/library';
    final libDir = Directory(libraryPath);
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
  Future<List<MediaItem>> pickExternalMediaFolderItems({
    void Function(int processed, int total)? onProgress,
  }) async {
    final sourceFolder = await pickFolder();
    if (sourceFolder == null) {
      return const <MediaItem>[];
    }
    return listMediaRecursiveFiles(sourceFolder, onProgress: onProgress);
  }

  @override
  Future<List<MediaItem>> resolveExternalItems(List<String> rawItems) async {
    final items = <MediaItem>[];
    final normalized = ImportSourceNormalizer.normalizeRawInputs(rawItems);
    for (final raw in normalized) {
      final item = await _externalItemFromRaw(raw.normalizedValue);
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

      // Build the index when it is missing or stale.
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
        final name = ent.uri.pathSegments.isNotEmpty
            ? ent.uri.pathSegments.last
            : ent.path;
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
      // 1) Return cached DB page first when available.
      final cached = await _tryListPageFromDb(
        folder,
        offset: offset,
        limit: limit,
      );
      if (cached != null) {
        // 2) Refresh the index in background if TTL expired.
        final idx = await _getFolderIndexRow(raw);
        if (idx != null && !_isIndexFresh(idx)) {
          // ignore: unawaited_futures
          _ensureFolderIndexSaf(raw);
        }
        return cached;
      }

      // Build the initial index, then serve the page from cached DB rows.
      await _ensureFolderIndexSaf(raw, force: true);
      final after = await _tryListPageFromDb(
        folder,
        offset: offset,
        limit: limit,
      );
      return after ?? const PagedMediaResult(items: [], total: 0);
    }
    // Filesystem-backed folders are paged directly from disk.
    final dir = Directory(raw);
    if (!await dir.exists()) return const PagedMediaResult(items: [], total: 0);

    final dirItems = <MediaItem>[];
    final fileItems = <MediaItem>[];

    await for (final ent in dir.list(recursive: false, followLinks: false)) {
      if (ent is Directory) {
        dirItems.add(
          MediaItem(
            id: ent.path,
            displayName: _fileName(ent.path),
            kind: MediaKind.folder,
            folderRaw: folder.raw,
            modified: null,
            tags: const [],
          ),
        );
      } else if (ent is File) {
        final name = ent.uri.pathSegments.isNotEmpty
            ? ent.uri.pathSegments.last
            : ent.path;
        if (!_isTargetFileName(name)) continue;

        final ext = _lowerExt(name);
        final kind = _mediaKindForExt(ext)!;
        final stat = await ent.stat();

        fileItems.add(
          MediaItem(
            id: ent.path,
            displayName: name,
            kind: kind,
            folderRaw: folder.raw,
            modified: stat.modified,
            tags: const [],
          ),
        );
      }
    }

    dirItems.sort(
      (a, b) =>
          a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
    );
    fileItems.sort(
      (a, b) =>
          a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
    );

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
    // SAF folders list only direct children.
    final entries = (await _getSafShallowCached(folder.raw)).entries;

    final folders = <MediaItem>[];
    final files = <MediaItem>[];

    int processed = 0;
    final total = entries.length;

    for (final e in entries) {
      if (e.isDir) {
        folders.add(
          MediaItem(
            id: e.documentUri, // Child folder document URI.
            displayName: e.name,
            kind: MediaKind.folder,
            folderRaw: folder.raw,
            modified: e.modified,
            tags: const [],
          ),
        );
      } else {
        final ext = _lowerExt(e.name);

        final kind = _mediaKindForExt(ext);
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

    // Return folders before files for a consistent gallery order.
    return <MediaItem>[...folders, ...files];
  }

  Future<List<MediaItem>> _listMediaFs(
    FolderHandle folder, {
    void Function(int processed, int total)? onProgress,
  }) async {
    final dir = Directory(folder.raw);
    if (!await dir.exists()) return const [];

    bool isTarget(FileSystemEntity e) {
      if (e is! File) return false;
      final name = e.uri.pathSegments.isNotEmpty
          ? e.uri.pathSegments.last
          : e.path;
      final ext = _lowerExt(name);
      return _mediaKindForExt(ext) != null;
    }

    // Count only target media when progress reporting is enabled.
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

      final kind = _mediaKindForExt(ext);
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
    final entries = await _safListRecursive(
      folder.raw,
      onProgress: onProgress,
      // Avoid a full pre-scan count on SAF folders because it can block the
      // UI for a long time before any progress is shown.
      total: 0,
    );

    // Convert file entries into MediaItem instances.
    final items = <MediaItem>[];
    for (final e in entries) {
      final ext = _lowerExt(e.name);
      final kind = _mediaKindForExt(ext);
      if (kind == null) continue;

      items.add(
        MediaItem(
          id: e.documentUri,
          displayName: e.name,
          kind: kind,
          folderRaw:
              folder.raw, // Preserve the registered root folder as folderRaw.
          modified: e.modified,
          tags: const [],
        ),
      );
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
      final name = e.uri.pathSegments.isNotEmpty
          ? e.uri.pathSegments.last
          : e.path;
      final ext = _lowerExt(name);
      return _mediaKindForExt(ext) != null;
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

      final name = ent.uri.pathSegments.isNotEmpty
          ? ent.uri.pathSegments.last
          : ent.path;
      final ext = _lowerExt(name);

      final kind = _mediaKindForExt(ext);
      if (kind == null) continue;

      final stat = await ent.stat();
      items.add(
        MediaItem(
          id: ent.path,
          displayName: name,
          kind: kind,
          folderRaw:
              folder.raw, // Preserve the registered root folder as folderRaw.
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
  Future<Uint8List> readBytes(MediaItem item) async {
    final rawId = item.id.trim();
    if (rawId.startsWith('content://')) {
      debugPrint(
        '[android-read] start source=content id=$rawId display=${item.displayName}',
      );
      try {
        final bytes = await _safReadBytes(rawId);
        debugPrint(
          '[android-read] success source=content bytes=${bytes.length} '
          'id=$rawId display=${item.displayName}',
        );
        return bytes;
      } catch (error, stackTrace) {
        debugPrint(
          '[android-read] failure source=content id=$rawId '
          'display=${item.displayName} error=$error',
        );
        debugPrintStack(
          label: '[android-read] failure stack',
          stackTrace: stackTrace,
        );
        rethrow;
      }
    }

    final sourceKind = rawId.startsWith('file://') ? 'file-uri' : 'path';
    late final String resolvedPath;
    try {
      resolvedPath = rawId.startsWith('file://')
          ? Uri.parse(rawId).toFilePath()
          : rawId;
    } catch (error, stackTrace) {
      debugPrint(
        '[android-read] uri parse failed source=$sourceKind id=$rawId '
        'display=${item.displayName} error=$error',
      );
      debugPrintStack(
        label: '[android-read] uri parse failed stack',
        stackTrace: stackTrace,
      );
      rethrow;
    }

    debugPrint(
      '[android-read] start source=$sourceKind id=$rawId '
      'display=${item.displayName} resolved=$resolvedPath',
    );
    try {
      final bytes = await File(resolvedPath).readAsBytes();
      debugPrint(
        '[android-read] success source=$sourceKind bytes=${bytes.length} '
        'id=$rawId resolved=$resolvedPath',
      );
      return bytes;
    } catch (error, stackTrace) {
      debugPrint(
        '[android-read] failure source=$sourceKind id=$rawId '
        'display=${item.displayName} resolved=$resolvedPath error=$error',
      );
      debugPrintStack(
        label: '[android-read] failure stack',
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  @override
  Future<Uint8List> readPdfSourceBytes(
    MediaItem item, {
    int maxWidth = 2800,
  }) async {
    if (_lowerExt(item.displayName) == '.avif' ||
        _lowerExt(item.id) == '.avif') {
      return renderPageBytes(item, 1, maxWidth: maxWidth);
    }
    return readBytes(item);
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
      if (_lowerExt(item.displayName) == '.avif' ||
          _lowerExt(item.id) == '.avif') {
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
    if (page < 1 || page > total) {
      throw RangeError.range(page, 1, total, 'page');
    }
    return _renderPage(item.id, doc, page, maxWidth);
  }

  @override
  Future<Uint8List> renderStaticPageBytes(
    MediaItem item,
    int page, {
    int maxWidth = 1600,
  }) {
    return renderPageBytes(item, page, maxWidth: maxWidth);
  }

  @override
  Future<ThumbPair> readThumbPair(MediaItem item, {int maxWidth = 360}) async {
    final cacheKey = '${item.id}|$maxWidth';

    // 1) In-memory cache.
    final cached = _thumbCache.get(cacheKey);
    if (cached != null) return cached;

    // 2) Reuse in-flight thumbnail work for the same cache key.
    final inflight = _thumbInFlight[cacheKey];
    if (inflight != null) return inflight;

    final future = () async {
      await _acquireThumbSlot(_thumbConcurrencyFor(item));
      try {
        // 3) Disk cache.
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
          // Fall back to fresh generation when the disk cache misses.
        }

        // 4) Generate thumbnails.
        final pair = await _buildThumbPair(item, maxWidth);

        // 5) Save to memory cache and opportunistically persist to disk.
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
      final thumb = await _readImageThumb(item, maxWidth);
      return ThumbPair(front: thumb, back: null);
    }

    return _lockOf(item.id).synchronized(() async {
      PdfDocument? doc;
      try {
        doc = await _openPdfForThumbnail(item.id);
        final front = await _renderPage(item.id, doc, 1, maxWidth);
        return ThumbPair(front: front, back: null);
      } finally {
        if (doc != null) {
          await doc.close();
        }
      }
    });
  }

  Future<Uint8List> _readImageThumb(MediaItem item, int maxWidth) async {
    try {
      final sourcePath = await _thumbSourcePathForImage(item);
      return await _makeImageThumbFromPath(sourcePath, maxWidth);
    } catch (error, stackTrace) {
      debugPrint(
        '[android-thumb] file-path thumb fallback item=${item.id} '
        'display=${item.displayName} error=$error',
      );
      debugPrintStack(
        label: '[android-thumb] file-path thumb fallback stack',
        stackTrace: stackTrace,
      );
      final bytes = await readBytes(item);
      return _makeImageThumb(bytes, maxWidth);
    }
  }

  Future<String> _thumbSourcePathForImage(MediaItem item) async {
    final rawId = item.id.trim();
    if (rawId.startsWith('content://')) {
      return _cachedFilePathForContentUri(rawId);
    }
    if (rawId.startsWith('file://')) {
      return Uri.parse(rawId).toFilePath();
    }
    return rawId;
  }

  Future<PdfDocument> _openPdfForThumbnail(String documentUri) async {
    if (documentUri.startsWith('content://')) {
      return _docmanSync(() async {
        final docFile = await DocumentFile.fromUri(documentUri);
        if (docFile == null) {
          throw Exception('DocumentFile.fromUri failed: $documentUri');
        }

        final cachedFile = await docFile.cache();
        if (cachedFile == null) {
          throw Exception('cache() failed: $documentUri');
        }

        return PdfDocument.openFile(cachedFile.path);
      });
    }

    final file = File(documentUri);
    if (!await file.exists()) {
      throw Exception('PDF file not found: $documentUri');
    }
    return PdfDocument.openFile(documentUri);
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
          if (docFile == null)
            throw Exception('DocumentFile.fromUri failed: $documentUri');

          final cachedFile = await docFile.cache();
          if (cachedFile == null)
            throw Exception('cache() failed: $documentUri');

          return PdfDocument.openFile(cachedFile.path);
        });
      } else {
        final f = File(documentUri);
        if (!await f.exists())
          throw Exception('PDF file not found: $documentUri');
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
    return _mediaKindForExt(ext) != null;
  }

  MediaKind? _mediaKindForExt(String ext) {
    if (ext == _pdfExt) return MediaKind.pdf;
    if (ext == _epubExt) return MediaKind.epub;
    if (_imageExt.contains(ext)) return MediaKind.image;
    return null;
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

      final rawName = doc.name.trim();
      final name = rawName.isNotEmpty ? rawName : _fileName(uri);
      if (!_isTargetFileName(name)) return null;

      final ext = _lowerExt(name);
      return MediaItem(
        id: uri,
        displayName: name,
        kind: _mediaKindForExt(ext)!,
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
      kind: _mediaKindForExt(ext)!,
      folderRaw: file.parent.path,
      modified: stat.modified,
      tags: const [],
    );
  }

  @override
  Future<MediaItem> rename(MediaItem item, String newDisplayName) async {
    final fixedName = ItemNameService.buildDisplayName(item, newDisplayName);
    String formatRenameError(Object? error) {
      final detail = error?.toString().trim() ?? '';
      if (detail.isEmpty) {
        return '名前の変更に失敗しました: $fixedName';
      }
      return '名前の変更に失敗しました: $fixedName ($detail)';
    }

    if (!item.id.startsWith('content://')) {
      final newPath = '${item.folderRaw}${Platform.pathSeparator}$fixedName';
      if (item.kind == MediaKind.folder) {
        final dir = Directory(item.id);
        if (!await dir.exists()) {
          throw Exception('名前を変更するフォルダが見つかりません: ${item.id}');
        }
        await LocalPathOperationService.renameItem(
          sourcePath: item.id,
          targetPath: newPath,
          isDirectory: true,
        );
      } else {
        final file = File(item.id);
        if (!await file.exists()) {
          throw Exception('名前を変更するファイルが見つかりません: ${item.id}');
        }
        await LocalPathOperationService.renameItem(
          sourcePath: item.id,
          targetPath: newPath,
          isDirectory: false,
        );
      }

      _thumbCache.clear();
      for (final doc in _pdfCache.values) {
        try {
          await doc.close();
        } catch (_) {}
      }
      _pdfCache.clear();
      return MediaItem(
        id: newPath,
        displayName: fixedName,
        kind: item.kind,
        folderRaw: item.folderRaw,
        modified: DateTime.now(),
        sizeBytes: item.sizeBytes,
        tags: item.tags,
      );
    }

    return _docmanSync(() async {
      final src = await DocumentFile.fromUri(item.id);
      if (src == null) {
        throw Exception('rename: src not found: ${item.id}');
      }

      final dir = await DocumentFile.fromUri(item.folderRaw);
      if (dir == null || dir.isDirectory != true) {
        throw Exception('rename: parent dir not found: ${item.folderRaw}');
      }

      final conflict = await dir.find(fixedName);
      if (conflict != null &&
          conflict.exists == true &&
          conflict.uri != src.uri) {
        throw Exception('同名のファイルまたはフォルダが既に存在します');
      }
      if (conflict != null &&
          conflict.exists == true &&
          conflict.uri == src.uri) {
        return MediaItem(
          id: src.uri,
          displayName: fixedName,
          kind: item.kind,
          folderRaw: item.folderRaw,
          modified: DateTime.now(),
          sizeBytes: item.sizeBytes,
          tags: item.tags,
        );
      }

      final d = src as dynamic;
      DocumentFile? moved;
      Object? lastRenameError;

      try {
        final r = await d.moveTo(dir, newName: fixedName);
        if (r is DocumentFile) moved = r;
      } catch (error, stackTrace) {
        lastRenameError = error;
        debugPrint('[RENAME][SAF] moveTo(dir, newName) failed: $error');
        debugPrintStack(
          label: '[RENAME][SAF] moveTo(dir, newName)',
          stackTrace: stackTrace,
        );
      }

      if (moved == null) {
        try {
          final r = await d.moveTo(dir, name: fixedName);
          if (r is DocumentFile) moved = r;
        } catch (error, stackTrace) {
          lastRenameError = error;
          debugPrint('[RENAME][SAF] moveTo(dir, name) failed: $error');
          debugPrintStack(
            label: '[RENAME][SAF] moveTo(dir, name)',
            stackTrace: stackTrace,
          );
        }
      }

      if (moved == null) {
        try {
          final r = await d.moveTo(dir: dir, newName: fixedName);
          if (r is DocumentFile) moved = r;
        } catch (error, stackTrace) {
          lastRenameError = error;
          debugPrint('[RENAME][SAF] moveTo(dir:, newName) failed: $error');
          debugPrintStack(
            label: '[RENAME][SAF] moveTo(dir:, newName)',
            stackTrace: stackTrace,
          );
        }
      }

      if (moved == null) {
        try {
          final r = await d.renameTo(fixedName);
          if (r is DocumentFile) {
            moved = r;
          } else if (r == true) {
            moved = await dir.find(fixedName);
          }
        } catch (error, stackTrace) {
          lastRenameError = error;
          debugPrint('[RENAME][SAF] renameTo failed: $error');
          debugPrintStack(
            label: '[RENAME][SAF] renameTo',
            stackTrace: stackTrace,
          );
        }
      }

      if (moved == null && lastRenameError != null) {
        throw Exception(formatRenameError(lastRenameError));
      }

      if (moved == null) {
        throw Exception('この保存先では名前変更に対応していません');
      }

      _invalidateSafShallowAll();
      await _invalidateFolderIndex(item.folderRaw);
      for (final doc in _pdfCache.values) {
        try {
          await doc.close();
        } catch (_) {}
      }
      _pdfCache.clear();

      return MediaItem(
        id: moved.uri,
        displayName: fixedName,
        kind: item.kind,
        folderRaw: item.folderRaw,
        modified: DateTime.now(),
        sizeBytes: item.sizeBytes,
        tags: item.tags,
      );
    });
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
          final name = f.name.trim();
          if (name.isEmpty) continue;

          final isDir = f.isDirectory == true;
          if (isDir) {
            if (f.uri.isNotEmpty) queue.add(f.uri);
            continue;
          }

          final ext = _lowerExt(name);
          if (_mediaKindForExt(ext) == null) continue;

          out.add(
            _SafEntry(
              documentUri: f.uri,
              name: name,
              modified: _toDateTimeSafe(f.lastModified),
              isDir: false,
            ),
          );

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

    final pickedItems = await pickExternalMediaFiles(
      allowMultiple: true,
      includeImages: true,
      includePdf: true,
    );
    if (pickedItems.isEmpty) return 0;

    return importItemsIntoFolder(
      folder,
      pickedItems,
      importMetadata: request?.metadata,
      skipIfExists: request?.skipIfExists ?? true,
      onProgress: onProgress,
    );

    /*
    if (!folder.raw.startsWith('content://')) {
      final dir = Directory(folder.raw);
      if (!await dir.exists()) await dir.create(recursive: true);

      int ok = 0;
      for (final f in picked) {
        try {
          final copied = await LocalPathOperationService.copyItem(
            sourcePath: f.path,
            targetPath: '${dir.path}/${f.path.split('/').last}',
            overwrite: overwriteExisting,
          );
          if (copied) {
            ok++;
          }
        } catch (_) {}
      }
      return ok;
    }

    return _docmanSync(() async {
      final dir = await DocumentFile.fromUri(folder.raw);
      if (dir == null)
        throw Exception('DocumentFile.fromUri failed: ${folder.raw}');
      if (dir.isDirectory != true)
        throw Exception('Target is not a directory: ${folder.raw}');

      if (dir.canCreate == true) {
        int ok = 0;
        for (final f in picked) {
          try {
            final name = f.path.split('/').last;
            final bytes = await f.readAsBytes();
            if (bytes.isEmpty) continue;

            final existing = await dir.find(name);
            if (existing != null && existing.exists == true) {
              if (!overwriteExisting) {
                continue;
              }
              final deleted = await _deleteDoc(existing);
              if (!deleted) {
                throw Exception('同名のファイルまたはフォルダが既に存在します');
              }
            }

            final created = await _createFile(dir, name, bytes);
            if (created != null) ok++;
          } catch (_) {}
        }
        _invalidateSafShallow(folder.raw);
        await _invalidateFolderIndex(folder.raw);
        return ok;
      }

      final lib = await getAppLibraryFolder();
      final libDir = Directory(lib.raw);
      if (!await libDir.exists()) await libDir.create(recursive: true);

      int ok = 0;
      for (final f in picked) {
        try {
          final copied = await LocalPathOperationService.copyItem(
            sourcePath: f.path,
            targetPath: '${libDir.path}/${f.path.split('/').last}',
            overwrite: overwriteExisting,
          );
          if (copied) {
            ok++;
          }
        } catch (_) {}
      }
      return ok;
    });
    */
  }

  @override
  Future<UrlImportResult> importFromUrlIntoFolder(
    FolderHandle folder,
    String sourceUrl, {
    ImportMetadata? importMetadata,
    UrlImportOptions? options,
    void Function(MediaTransferProgress progress)? onProgress,
  }) async {
    final trimmedUrl = sourceUrl.trim();
    final effectiveOptions = options ?? const UrlImportOptions();
    if (!effectiveOptions.hasAnySource(trimmedUrl)) {
      throw Exception('URL を入力してください');
    }

    if (!folder.raw.startsWith('content://')) {
      final destDir = Directory(folder.raw);
      if (!await destDir.exists()) {
        await destDir.create(recursive: true);
      }
      final result = await _urlImportDownloader.downloadUrl(
        sourceUrl: trimmedUrl,
        destinationFolder: destDir.path,
        options: effectiveOptions,
        onProgress: onProgress,
      );
      return UrlImportResult(
        importedCount: result.importedCount,
        skippedCount: result.skippedCount,
        failedCount: result.failedCount,
        logLines: result.logLines,
        hitomiMetadataByRelativePath: result.hitomiMetadataByRelativePath,
      );
    }

    final stagingRoot = await getTemporaryDirectory();
    final stagingDir = Directory(
      '${stagingRoot.path}/url_import_${DateTime.now().millisecondsSinceEpoch}',
    );
    await stagingDir.create(recursive: true);

    try {
      final downloadResult = await _urlImportDownloader.downloadUrl(
        sourceUrl: trimmedUrl,
        destinationFolder: stagingDir.path,
        options: effectiveOptions,
        onProgress: onProgress,
      );

      final stagedItems = await _listFilesystemMediaItems(stagingDir);
      if (stagedItems.isEmpty) {
        return UrlImportResult(
          importedCount: downloadResult.importedCount,
          skippedCount: downloadResult.skippedCount,
          failedCount: downloadResult.failedCount,
          logLines: downloadResult.logLines,
          hitomiMetadataByRelativePath:
              downloadResult.hitomiMetadataByRelativePath,
        );
      }

      onProgress?.call(
        MediaTransferProgress(
          sentBytes: stagedItems.length,
          totalBytes: stagedItems.length,
          completedFiles: 0,
          totalFiles: stagedItems.length,
          statusLabel: 'ホストにアップロードしています',
        ),
      );

      final importedCount = await importItemsIntoFolder(
        folder,
        stagedItems,
        importMetadata: importMetadata,
        skipIfExists: !effectiveOptions.overwriteExistingFiles,
        onProgress: onProgress,
      );

      final stagedCount = stagedItems
          .where((item) => item.kind != MediaKind.folder)
          .length;
      final importedSkips = (stagedCount - importedCount)
          .clamp(0, stagedCount)
          .toInt();
      return UrlImportResult(
        importedCount: importedCount,
        skippedCount: downloadResult.skippedCount + importedSkips,
        failedCount: downloadResult.failedCount,
        logLines: downloadResult.logLines,
        hitomiMetadataByRelativePath:
            downloadResult.hitomiMetadataByRelativePath,
      );
    } finally {
      if (await stagingDir.exists()) {
        try {
          await stagingDir.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  Future<List<MediaItem>> _listFilesystemMediaItems(Directory root) async {
    final items = <MediaItem>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      final name = entity.uri.pathSegments.isNotEmpty
          ? entity.uri.pathSegments.last
          : entity.path;
      final ext = _lowerExt(name);
      try {
        final kind = _mediaKindForExt(ext);
        if (kind == null) continue;
        final stat = await entity.stat();
        items.add(
          MediaItem(
            id: entity.path,
            displayName: name,
            kind: kind,
            folderRaw: entity.parent.path,
            modified: stat.modified,
            sizeBytes: stat.size,
          ),
        );
      } catch (_) {}
    }
    return items;
  }

  @override
  Future<int> importItemsIntoFolder(
    FolderHandle dest,
    List<MediaItem> items, {
    ImportMetadata? importMetadata,
    bool skipIfExists = true,
    void Function(MediaTransferProgress progress)? onProgress,
  }) async {
    if (!dest.raw.startsWith('content://')) {
      final dir = Directory(dest.raw);
      if (!await dir.exists()) await dir.create(recursive: true);

      int ok = 0;
      for (final it in items) {
        if (it.kind == MediaKind.folder) continue;

        try {
          final bytes = await readBytes(it);
          if (bytes.isEmpty) continue;

          final targetPath = '${dir.path}/${it.displayName}';
          final conflict = await LocalPathOperationService.checkNameConflict(
            sourcePath: it.id,
            targetPath: targetPath,
          );
          if (conflict == LocalPathConflictResult.sameFile) {
            debugPrint(
              '[MOVE] skipped same-file source=${it.id} target=$targetPath',
            );
            continue;
          }
          if (conflict == LocalPathConflictResult.duplicateName &&
              skipIfExists) {
            debugPrint(
              '[COPY] blocked duplicate-name source=${it.id} target=$targetPath',
            );
            continue;
          }
          if (conflict == LocalPathConflictResult.duplicateName) {
            await File(targetPath).delete();
          }

          await File(targetPath).writeAsBytes(bytes, flush: true);
          ok++;
        } catch (_) {}
      }
      return ok;
    }

    return _docmanSync(() async {
      final dir = await DocumentFile.fromUri(dest.raw);
      if (dir == null)
        throw Exception('DocumentFile.fromUri failed: ${dest.raw}');
      if (dir.isDirectory != true)
        throw Exception('Target is not a directory: ${dest.raw}');
      if (dir.canCreate != true)
        throw Exception('Target folder is not writable: ${dest.raw}');

      int ok = 0;
      for (final it in items) {
        if (it.kind == MediaKind.folder) continue;

        try {
          final bytes = await readBytes(it);
          if (bytes.isEmpty) continue;

          final existing = await dir.find(it.displayName);
          if (existing != null && existing.exists == true) {
            if (skipIfExists) {
              debugPrint(
                '[COPY] blocked duplicate-name source=${it.id} target=${it.displayName}',
              );
              continue;
            }
            final deleted = await _deleteDoc(existing);
            if (!deleted) {
              throw Exception('同名のファイルまたはフォルダが既に存在します');
            }
          }

          final created = await _createFile(dir, it.displayName, bytes);
          if (created != null) {
            ok++;
          }
        } catch (_) {}
      }

      _invalidateSafShallow(dest.raw);
      await _invalidateFolderIndex(dest.raw);
      return ok;
    });
  }

  // -------------------------
  // docman create/delete helpers with signature fallbacks.
  Future<DocumentFile?> _createFile(
    DocumentFile dir,
    String name,
    Uint8List bytes,
  ) async {
    final d = dir as dynamic;

    // Pattern 1: createFile(name: ..., bytes: ...)
    try {
      final r = await d.createFile(name: name, bytes: bytes);
      if (r is DocumentFile) return r;
    } catch (_) {}

    // Pattern 2: createFile(name, bytes)
    try {
      final r = await d.createFile(name, bytes);
      if (r is DocumentFile) return r;
    } catch (_) {}

    // Pattern 3: createFile(name: ..., mimeType: ..., bytes: ...)
    try {
      final mime = _mimeFor(itemExt: _lowerExt(name));
      final r = await d.createFile(name: name, mimeType: mime, bytes: bytes);
      if (r is DocumentFile) return r;
    } catch (_) {}

    return null;
  }

  Future<bool> _deleteDoc(DocumentFile doc) async {
    final d = doc as dynamic;
    // Pattern 1: delete()
    try {
      final r = await d.delete();
      if (r is bool) return r;
      return true;
    } catch (_) {}
    // Pattern 2: delete(recursive: false)
    try {
      final r = await d.delete(recursive: false);
      if (r is bool) return r;
      return true;
    } catch (_) {}
    // Pattern 3: deleteFile()
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
    // SAF folder deletion is not supported yet.
    if (item.kind == MediaKind.folder && item.id.startsWith('content://')) {
      return false;
    }

    // Delete local filesystem folders directly.
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

    // Delete SAF-backed images and PDFs.
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

    // Delete the local filesystem item directly when not using SAF.
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

  @override
  Future<MediaItem> deletePdfPage(MediaItem item, int pageNumber) async {
    throw UnsupportedError('Android の PDF ページ削除は未対応です');
  }

  String _mimeFor({required String itemExt}) {
    if (itemExt == '.pdf') return 'application/pdf';
    if (itemExt == '.epub') return 'application/epub+zip';
    return MediaFileTypes.imageMimeTypeForFileName(itemExt);
  }

  Future<_ShallowCacheEntry> _getSafShallowCached(String dirUri) async {
    final hit = _safShallowCache[dirUri];
    if (hit != null && DateTime.now().difference(hit.at) <= _safShallowTtl) {
      return hit;
    }

    final entries = await _safListShallow(dirUri);
    final dirs = <_SafEntry>[];
    final files = <_SafEntry>[];

    for (final entry in entries) {
      if (entry.isDir) {
        dirs.add(entry);
      } else if (_isTargetFileName(entry.name)) {
        files.add(entry);
      }
    }

    int compareByName(_SafEntry a, _SafEntry b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase());

    dirs.sort(compareByName);
    files.sort(compareByName);

    final cacheEntry = _ShallowCacheEntry(
      at: DateTime.now(),
      entries: entries,
      sortedAll: <_SafEntry>[...dirs, ...files],
    );

    _safShallowCache[dirUri] = cacheEntry;
    return cacheEntry;
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

class _LruCache<K, V extends Object> {
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
  ui.Image? image;
  try {
    final frame = await codec.getNextFrame();
    image = frame.image;

    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) return src;

    return byteData.buffer.asUint8List(
      byteData.offsetInBytes,
      byteData.lengthInBytes,
    );
  } finally {
    image?.dispose();
    codec.dispose();
  }
}

Future<Uint8List> _makeImageThumbFromPath(
  String sourcePath,
  int targetWidth,
) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;

  try {
    buffer = await ui.ImmutableBuffer.fromFilePath(sourcePath);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    codec = await descriptor.instantiateCodec(targetWidth: targetWidth);
    final frame = await codec.getNextFrame();
    image = frame.image;

    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) {
      throw Exception('Image thumbnail encoding failed: $sourcePath');
    }

    return byteData.buffer.asUint8List(
      byteData.offsetInBytes,
      byteData.lengthInBytes,
    );
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
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
// ==============================
// SAF shallow cache entry
// ==============================

class _ShallowCacheEntry {
  final DateTime at;
  final List<_SafEntry> entries;
  final List<_SafEntry> sortedAll;
  _ShallowCacheEntry({
    required this.at,
    required this.entries,
    required this.sortedAll,
  });
}
