import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

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

/// ------------------------------
/// LRU cache by entry count and byte size.
/// ------------------------------
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
    // Reinsert as the newest entry.
    _map[key] = v;
    return v;
  }

  void put(K key, V value) {
    final old = _map.remove(key);
    if (old != null) {
      _bytes -= sizeOf(old);
    }

    _map[key] = value;
    _bytes += sizeOf(value);

    _evictIfNeeded();
  }

  void _evictIfNeeded() {
    // Evict oldest entries until both limits are satisfied.
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

  int get bytes => _bytes;
  int get length => _map.length;
}

class _FsPageEntry {
  final String path;
  final String name;
  final MediaKind kind;
  final String? mimeType;

  const _FsPageEntry({
    required this.path,
    required this.name,
    required this.kind,
    this.mimeType,
  });
}

class WindowsFolderRepository implements MediaRepository {
  static const _pdfExt = '.pdf';
  static const _epubExt = '.epub';

  final UrlImportDownloaderService _urlImportDownloader =
      UrlImportDownloaderService();
  final AppSettingsService _settingsService = AppSettingsService();

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
    canEditPdfPages: true,
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

  @override
  Future<FolderHandle> getAppLibraryFolder() async {
    final settings = await _settingsService.loadMetadataSettings();
    final configuredPath = settings.hostLibraryPath.trim();
    final libraryPath = configuredPath.isNotEmpty
        ? configuredPath
        : '${(await getApplicationDocumentsDirectory()).path}${Platform.pathSeparator}library';
    final libDir = Directory(libraryPath);
    if (!await libDir.exists()) {
      await libDir.create(recursive: true);
    }
    return FolderHandle(libDir.path);
  }

  // ------------------------------
  // Thumbnail LRU cache.
  // ------------------------------
  // Upper bounds: 64MB / 400 entries.
  // Older entries are removed when either limit is exceeded.
  final _LruCache<String, ThumbPair> _thumbCache = _LruCache<String, ThumbPair>(
    maxBytes: 64 * 1024 * 1024,
    maxEntries: 400,
    sizeOf: (pair) =>
        pair.front.lengthInBytes + (pair.back?.lengthInBytes ?? 0),
  );

  // Share in-flight thumbnail builds for the same cache key.
  final Map<String, Future<ThumbPair>> _thumbInFlight = {};

  // PDF document cache for faster page rendering.
  final Map<String, PdfDocument> _pdfCache = {};
  Directory? _thumbDiskDir;

  bool _isUncPath(String path) => path.startsWith(r'\\');

  Future<Directory> _ensureThumbDiskDir() async {
    if (_thumbDiskDir != null) return _thumbDiskDir!;
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/thumbs_v2');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _thumbDiskDir = dir;
    return dir;
  }

  String _fnv1a64Hex(String value) {
    const int fnvOffset = 0xcbf29ce484222325;
    const int fnvPrime = 0x100000001b3;

    var hash = fnvOffset;
    final bytes = utf8.encode(value);
    for (final byte in bytes) {
      hash ^= byte;
      hash = (hash * fnvPrime) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  Future<File> _thumbDiskFile(String cacheKey) async {
    final dir = await _ensureThumbDiskDir();
    return File('${dir.path}/${_fnv1a64Hex(cacheKey)}.bin');
  }

  String _thumbCacheKey(MediaItem item, int maxWidth) {
    return [
      item.id,
      item.modified?.millisecondsSinceEpoch ?? 0,
      item.sizeBytes ?? 0,
      maxWidth,
      'thumb-v2',
    ].join('|');
  }

  Future<T> _withFsRetry<T>(
    String path,
    Future<T> Function() action, {
    int retries = 2,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt <= retries; attempt++) {
      try {
        return await action();
      } catch (error) {
        lastError = error;
        if (!_isUncPath(path) || attempt >= retries) {
          rethrow;
        }
        await Future<void>.delayed(Duration(milliseconds: 120 * (attempt + 1)));
      }
    }
    throw lastError ?? Exception('I/O error: $path');
  }

  @override
  Future<FolderHandle?> pickFolder() async {
    final path = await getDirectoryPath();
    if (path == null || path.isEmpty) return null;
    return FolderHandle(path);
  }

  @override
  Future<MediaItem?> pickSinglePdf() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'PDF', extensions: ['pdf']),
      ],
    );
    if (file == null || file.path.isEmpty) return null;
    return _mediaItemFromPath(file.path);
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

    final files = allowMultiple
        ? await openFiles(
            acceptedTypeGroups: [
              XTypeGroup(label: 'Media', extensions: extensions),
            ],
          )
        : [
            if (await openFile(
                  acceptedTypeGroups: [
                    XTypeGroup(label: 'Media', extensions: extensions),
                  ],
                )
                case final picked?)
              picked,
          ];

    final items = <MediaItem>[];
    for (final file in files) {
      final item = await _mediaItemFromPath(file.path);
      if (item != null) {
        items.add(item);
      }
    }
    return items;
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
      final item = await _mediaItemFromPath(raw.normalizedValue);
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
    final dir = Directory(folder.raw);
    if (!await dir.exists()) return const [];

    bool isMediaFile(FileSystemEntity e) {
      if (e is! File) return false;
      final name = e.uri.pathSegments.isNotEmpty
          ? e.uri.pathSegments.last
          : e.path;
      final ext = _lowerExt(name);
      return MediaFileTypes.imageExtensions.contains(ext) ||
          ext == _pdfExt ||
          ext == _epubExt;
    }

    // Read entries once so progress can use a stable total.
    final entries = <FileSystemEntity>[];
    await for (final e in dir.list(recursive: false, followLinks: false)) {
      entries.add(e);
    }

    final total = entries.length;
    int processed = 0;

    final folders = <MediaItem>[];
    final files = <MediaItem>[];

    for (final e in entries) {
      // Directories are shown before files.
      if (e is Directory) {
        final stat = await e.stat();
        final name = _fileName(e.path);
        final isGifCollection = await _isGifCollectionDirectory(e);
        folders.add(
          MediaItem(
            id: e.path,
            displayName: name,
            kind: isGifCollection ? MediaKind.pdf : MediaKind.folder,
            folderRaw: folder.raw,
            mimeType: isGifCollection ? 'application/x.gif-collection' : null,
            modified: stat.modified,
            tags: const [],
          ),
        );

        processed++;
        if (onProgress != null) onProgress(processed, total);
        continue;
      }

      // Skip unsupported direct child files.
      if (!isMediaFile(e)) {
        processed++;
        if (onProgress != null) onProgress(processed, total);
        continue;
      }

      final f = e as File;
      final name = _fileName(f.path);
      final ext = _lowerExt(name);

      final kind = _mediaKindForExt(ext);
      if (kind == null) continue;
      final stat = await f.stat();

      files.add(
        MediaItem(
          id: f.path,
          displayName: name,
          kind: kind,
          folderRaw: folder.raw,
          modified: stat.modified,
          sizeBytes: stat.size,
          tags: const [],
        ),
      );

      processed++;
      if (onProgress != null) onProgress(processed, total);
    }

    // Sort folders first, then files, by display name.
    folders.sort(
      (a, b) =>
          a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
    );
    files.sort(
      (a, b) =>
          a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
    );

    return <MediaItem>[...folders, ...files];
  }

  @override
  Future<int> countMedia(FolderHandle folder) async {
    final dir = Directory(folder.raw);
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
    final dir = Directory(folder.raw);
    if (!await dir.exists()) {
      return const PagedMediaResult(items: [], total: 0);
    }

    final entries = <_FsPageEntry>[];

    await for (final ent in dir.list(recursive: false, followLinks: false)) {
      if (ent is Directory) {
        final isGifCollection = await _isGifCollectionDirectory(ent);
        entries.add(
          _FsPageEntry(
            path: ent.path,
            name: _fileName(ent.path),
            kind: isGifCollection ? MediaKind.pdf : MediaKind.folder,
            mimeType: isGifCollection ? 'application/x.gif-collection' : null,
          ),
        );
        continue;
      }

      if (ent is File) {
        final name = ent.uri.pathSegments.isNotEmpty
            ? ent.uri.pathSegments.last
            : ent.path;
        if (!_isTargetFileName(name)) continue;

        final ext = _lowerExt(name);
        final kind = _mediaKindForExt(ext);
        if (kind == null) continue;
        entries.add(_FsPageEntry(path: ent.path, name: name, kind: kind));
      }
    }

    entries.sort((left, right) {
      final leftKindOrder = left.kind == MediaKind.folder ? 0 : 1;
      final rightKindOrder = right.kind == MediaKind.folder ? 0 : 1;
      if (leftKindOrder != rightKindOrder) {
        return leftKindOrder.compareTo(rightKindOrder);
      }
      return left.name.toLowerCase().compareTo(right.name.toLowerCase());
    });

    final total = entries.length;

    final start = offset.clamp(0, total);
    final end = (start + limit).clamp(0, total);
    final slice = entries.sublist(start, end);

    final items = <MediaItem>[];
    var processed = 0;

    for (final entry in slice) {
      if (entry.kind == MediaKind.folder) {
        final stat = await _withFsRetry(
          entry.path,
          () => Directory(entry.path).stat(),
        );
        items.add(
          MediaItem(
            id: entry.path,
            displayName: entry.name,
            kind: MediaKind.folder,
            folderRaw: folder.raw,
            mimeType: entry.mimeType,
            modified: stat.modified,
            tags: const [],
          ),
        );
      } else {
        final isGifCollection =
            entry.mimeType == 'application/x.gif-collection';
        final stat = await _withFsRetry(
          entry.path,
          () => isGifCollection
              ? Directory(entry.path).stat()
              : File(entry.path).stat(),
        );
        items.add(
          MediaItem(
            id: entry.path,
            displayName: entry.name,
            kind: entry.kind,
            folderRaw: folder.raw,
            mimeType: entry.mimeType,
            modified: stat.modified,
            sizeBytes: stat.size,
            tags: const [],
          ),
        );
      }

      processed++;
      if (onProgress != null) {
        onProgress(processed, slice.length);
      }
    }

    return PagedMediaResult(items: items, total: total);
  }

  @override
  Future<List<MediaItem>> listMediaRecursiveFiles(
    FolderHandle folder, {
    void Function(int processed, int total)? onProgress,
  }) async {
    // Windows uses direct filesystem traversal.
    return _listMediaFsRecursiveFiles(folder, onProgress: onProgress);
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
    final gifCollectionDirs = <String>{};

    await for (final ent in dir.list(recursive: true, followLinks: false)) {
      if (ent is Directory) {
        if (await _isGifCollectionDirectory(ent)) {
          final stat = await ent.stat();
          final normalized = _normalizedFsPath(ent.path);
          gifCollectionDirs.add(normalized);
          items.add(
            MediaItem(
              id: ent.path,
              displayName: _fileName(ent.path),
              kind: MediaKind.pdf,
              folderRaw: folder.raw,
              mimeType: 'application/x.gif-collection',
              modified: stat.modified,
              tags: const [],
            ),
          );
        }
        continue;
      }
      if (ent is! File) continue;
      if (gifCollectionDirs.contains(_normalizedFsPath(ent.parent.path))) {
        continue;
      }

      final name = ent.uri.pathSegments.isNotEmpty
          ? ent.uri.pathSegments.last
          : ent.path;
      final ext = _lowerExt(name);

      MediaKind? kind;
      kind = _mediaKindForExt(ext);
      if (kind == null) continue;

      final stat = await ent.stat();
      items.add(
        MediaItem(
          id: ent.path,
          displayName: name,
          kind: kind,
          folderRaw: folder.raw,
          modified: stat.modified,
          sizeBytes: stat.size,
          tags: const [],
        ),
      );

      processed++;
      if (onProgress != null) onProgress(processed, total);
    }

    return items;
  }

  bool _isInsideLibrary(String path, String libraryRoot) {
    var p = path.replaceAll('/', '\\').toLowerCase();
    var root = libraryRoot.replaceAll('/', '\\').toLowerCase();
    return p == root || p.startsWith('$root\\');
  }

  @override
  Future<bool> deleteItem(MediaItem item) async {
    try {
      if (item.kind == MediaKind.folder) {
        final dir = Directory(item.id);
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }

        _thumbCache.clear();

        final keys = _pdfCache.keys.toList(growable: false);
        for (final k in keys) {
          if (_isInsideLibrary(k, item.id)) {
            final doc = _pdfCache.remove(k);
            if (doc != null) {
              try {
                await doc.close();
              } catch (_) {}
            }
          }
        }
        return true;
      }

      final f = File(item.id);
      if (await f.exists()) {
        await f.delete();
      }

      _thumbCache.clear();
      final doc = _pdfCache.remove(item.id);
      if (doc != null) {
        try {
          await doc.close();
        } catch (_) {}
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
    if (item.kind != MediaKind.pdf) {
      throw ArgumentError('PDF ではありません');
    }

    final total = await getPageCount(item);
    if (total <= 1) {
      throw StateError('最後の1ページは削除できません');
    }
    if (pageNumber < 1 || pageNumber > total) {
      throw RangeError.range(pageNumber, 1, total, 'pageNumber');
    }

    final cachedDoc = _pdfCache.remove(item.id);
    if (cachedDoc != null) {
      await cachedDoc.close();
    }

    final bytes = await _withFsRetry(
      item.id,
      () => File(item.id).readAsBytes(),
    );
    final document = sf.PdfDocument(inputBytes: bytes);
    late final List<int> updatedBytes;
    try {
      document.pages.removeAt(pageNumber - 1);
      updatedBytes = await document.save();
    } finally {
      document.dispose();
    }

    final file = File(item.id);
    await _withFsRetry(
      item.id,
      () => file.writeAsBytes(updatedBytes, flush: true),
    );
    _thumbCache.clear();

    final stat = await file.stat();
    return MediaItem(
      id: item.id,
      displayName: item.displayName,
      kind: item.kind,
      folderRaw: item.folderRaw,
      modified: stat.modified,
      sizeBytes: stat.size,
      tags: item.tags,
    );
  }

  @override
  Future<Uint8List> readBytes(MediaItem item) async {
    if (ItemNameService.isGifCollection(item)) {
      return renderPageBytes(item, 1);
    }
    final rawId = item.id.trim();
    final sourceKind = rawId.startsWith('file://') ? 'file-uri' : 'path';
    late final String resolvedPath;
    try {
      resolvedPath = rawId.startsWith('file://')
          ? Uri.parse(rawId).toFilePath()
          : rawId;
    } catch (error, stackTrace) {
      debugPrint(
        '[local-read] uri parse failed source=$sourceKind id=$rawId '
        'display=${item.displayName} error=$error',
      );
      debugPrintStack(
        label: '[local-read] uri parse failed stack',
        stackTrace: stackTrace,
      );
      rethrow;
    }

    debugPrint(
      '[local-read] start source=$sourceKind id=$rawId '
      'display=${item.displayName} resolved=$resolvedPath',
    );
    try {
      final bytes = await _withFsRetry(
        resolvedPath,
        () => File(resolvedPath).readAsBytes(),
      );
      debugPrint(
        '[local-read] success source=$sourceKind bytes=${bytes.length} '
        'id=$rawId resolved=$resolvedPath',
      );
      return bytes;
    } catch (error, stackTrace) {
      debugPrint(
        '[local-read] failure source=$sourceKind id=$rawId '
        'display=${item.displayName} resolved=$resolvedPath error=$error',
      );
      debugPrintStack(
        label: '[local-read] failure stack',
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
    if (ItemNameService.isGifCollection(item)) {
      return renderPageBytes(item, 1, maxWidth: maxWidth);
    }
    if (_isAvifPath(item.id) || _isAvifPath(item.displayName)) {
      return renderPageBytes(item, 1, maxWidth: maxWidth);
    }
    return readBytes(item);
  }

  bool _isAvifPath(String path) => _lowerExt(path) == '.avif';

  String _normalizedFsPath(String path) {
    return path.replaceAll('\\', '/').toLowerCase();
  }

  Future<bool> _isGifCollectionDirectory(Directory dir) async {
    return (await _gifCollectionPageFiles(dir)).isNotEmpty;
  }

  Future<List<File>> _gifCollectionPageFiles(Directory dir) async {
    if (!await dir.exists()) {
      return const <File>[];
    }
    final pages = <File>[];
    await for (final ent in dir.list(recursive: false, followLinks: false)) {
      if (ent is! File) {
        continue;
      }
      if (await _isGifCollectionMemberFile(ent)) {
        pages.add(ent);
      }
    }
    pages.sort(
      (a, b) => _fileName(
        a.path,
      ).toLowerCase().compareTo(_fileName(b.path).toLowerCase()),
    );
    return pages;
  }

  Future<bool> _isGifCollectionMemberFile(File file) async {
    final ext = _lowerExt(file.path);
    if (ext == '.gif') {
      return true;
    }
    if (ext != '.webp') {
      return false;
    }
    try {
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      try {
        return codec.frameCount > 1;
      } finally {
        codec.dispose();
      }
    } catch (_) {
      return false;
    }
  }

  Future<Uint8List> _makeImageThumb(Uint8List src, int targetWidth) async {
    if (src.isEmpty) return src;
    final codec = await ui.instantiateImageCodec(src, targetWidth: targetWidth);
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      try {
        final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
        if (byteData == null) return src;
        return byteData.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }

  Future<Uint8List> _readImageBytesForDisplay(
    MediaItem item, {
    required int maxWidth,
  }) async {
    final bytes = await readBytes(item);
    if (!_isAvifPath(item.id)) {
      return bytes;
    }
    try {
      return await _makeImageThumb(bytes, maxWidth);
    } catch (_) {
      return bytes;
    }
  }

  // ---- PDF page count ----
  @override
  Future<int> getPageCount(MediaItem item) async {
    if (item.kind != MediaKind.pdf) return 1;
    if (ItemNameService.isGifCollection(item)) {
      return (await _gifCollectionPageFiles(Directory(item.id))).length;
    }
    final doc = await _openPdf(item.id);
    return doc.pagesCount;
  }

  // ---- PDF/image page rendering ----
  @override
  Future<Uint8List> renderPageBytes(
    MediaItem item,
    int page, {
    int maxWidth = 1600,
  }) async {
    if (item.kind != MediaKind.pdf) {
      return _readImageBytesForDisplay(item, maxWidth: maxWidth);
    }
    if (ItemNameService.isGifCollection(item)) {
      final pages = await _gifCollectionPageFiles(Directory(item.id));
      if (page < 1 || page > pages.length) {
        throw RangeError.range(page, 1, pages.length, 'page');
      }
      return pages[page - 1].readAsBytes();
    }

    final doc = await _openPdf(item.id);
    final total = doc.pagesCount;
    if (page < 1 || page > total) {
      throw RangeError.range(page, 1, total, 'page');
    }

    return _renderPage(doc, page, maxWidth);
  }

  @override
  Future<Uint8List> renderStaticPageBytes(
    MediaItem item,
    int page, {
    int maxWidth = 1600,
  }) async {
    final bytes = await renderPageBytes(item, page, maxWidth: maxWidth);
    if (!ItemNameService.isGifCollection(item)) {
      return bytes;
    }
    try {
      return await _makeImageThumb(bytes, maxWidth);
    } catch (_) {
      return bytes;
    }
  }

  @override
  Future<ThumbPair> readThumbPair(MediaItem item, {int maxWidth = 360}) async {
    final cacheKey = _thumbCacheKey(item, maxWidth);

    // Try the in-memory LRU cache first.
    final cached = _thumbCache.get(cacheKey);
    if (cached != null) return cached;

    // Reuse an in-flight build for the same key.
    final inflight = _thumbInFlight[cacheKey];
    if (inflight != null) return inflight;

    // 菴懈・・・n-flight 逋ｻ骭ｲ・・
    final future =
        (() async {
          try {
            final diskFile = await _thumbDiskFile(cacheKey);
            if (await diskFile.exists()) {
              final bytes = await diskFile.readAsBytes();
              if (bytes.isNotEmpty) {
                final pair = ThumbPair(front: bytes, back: null);
                _thumbCache.put(cacheKey, pair);
                return pair;
              }
            }
          } catch (_) {
            // Fall through to fresh generation.
          }

          final pair = await _buildThumbPair(item, maxWidth);
          _thumbCache.put(cacheKey, pair);
          try {
            final diskFile = await _thumbDiskFile(cacheKey);
            await diskFile.writeAsBytes(pair.front, flush: false);
          } catch (_) {}
          return pair;
        })().whenComplete(() {
          _thumbInFlight.remove(cacheKey);
        });

    _thumbInFlight[cacheKey] = future;
    return future;
  }

  Future<ThumbPair> _buildThumbPair(MediaItem item, int maxWidth) async {
    if (ItemNameService.isGifCollection(item)) {
      final bytes = await renderStaticPageBytes(item, 1, maxWidth: maxWidth);
      return ThumbPair(front: bytes, back: null);
    }

    if (item.kind == MediaKind.image) {
      final bytes = await _withFsRetry(
        item.id,
        () => File(item.id).readAsBytes(),
      );
      try {
        final thumb = await _makeImageThumb(bytes, maxWidth);
        return ThumbPair(front: thumb, back: null);
      } catch (_) {
        return ThumbPair(front: bytes, back: null);
      }
    }

    // PDF: render the first page for the thumbnail.
    final doc = await _withFsRetry(
      item.id,
      () => PdfDocument.openFile(item.id),
    );
    try {
      final front = await _renderPage(doc, 1, maxWidth);
      return ThumbPair(front: front, back: null);
    } finally {
      await doc.close();
    }
  }

  // ---- PDF open with cache ----
  Future<PdfDocument> _openPdf(String path) async {
    final cached = _pdfCache[path];
    if (cached != null) return cached;

    final doc = await _withFsRetry(path, () => PdfDocument.openFile(path));
    _pdfCache[path] = doc;
    return doc;
  }

  // ---- PDF page render ----
  Future<Uint8List> _renderPage(
    PdfDocument doc,
    int pageNumber,
    int maxWidth,
  ) async {
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

    if (img == null) {
      throw Exception('PDF render failed (page=$pageNumber)');
    }
    return img.bytes;
  }

  /// Releases cached PDF documents and thumbnail state.
  Future<void> dispose() async {
    _thumbInFlight.clear();
    _thumbCache.clear();
    for (final doc in _pdfCache.values) {
      await doc.close();
    }
    _pdfCache.clear();
  }

  static String _fileName(String path) {
    final sep = Platform.pathSeparator;
    final idx = path.lastIndexOf(sep);
    return idx >= 0 ? path.substring(idx + 1) : path;
  }

  static String _lowerExt(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0) return '';
    return path.substring(dot).toLowerCase();
  }

  bool _isTargetFileName(String name) {
    final ext = _lowerExt(name);
    return _mediaKindForExt(ext) != null;
  }

  MediaKind? _mediaKindForExt(String ext) {
    if (ext == _pdfExt) return MediaKind.pdf;
    if (ext == _epubExt) return MediaKind.epub;
    if (MediaFileTypes.imageExtensions.contains(ext)) return MediaKind.image;
    return null;
  }

  Future<MediaItem?> _mediaItemFromPath(String rawPath) async {
    if (rawPath.isEmpty) return null;
    final path = rawPath.startsWith('file://')
        ? Uri.parse(rawPath).toFilePath()
        : rawPath;
    final file = File(path);
    if (!await file.exists()) return null;

    final name = _fileName(path);
    if (!_isTargetFileName(name)) return null;

    final ext = _lowerExt(name);
    final stat = await file.stat();
    return MediaItem(
      id: path,
      displayName: name,
      kind: _mediaKindForExt(ext)!,
      folderRaw: file.parent.path,
      modified: stat.modified,
      sizeBytes: stat.size,
      tags: const [],
    );
  }

  @override
  Future<MediaItem> rename(MediaItem item, String newDisplayName) async {
    final oldPath = item.id;
    final fixedName = ItemNameService.buildDisplayName(item, newDisplayName);
    final newPath = '${item.folderRaw}${Platform.pathSeparator}$fixedName';

    if (item.kind == MediaKind.folder) {
      final oldDir = Directory(oldPath);
      if (!await oldDir.exists()) {
        throw Exception('Folder not found: $oldPath');
      }

      await LocalPathOperationService.renameItem(
        sourcePath: oldPath,
        targetPath: newPath,
        isDirectory: true,
      );
      _thumbCache.clear();
      final keys = _pdfCache.keys.toList(growable: false);
      for (final key in keys) {
        if (_isInsideLibrary(key, oldPath) || _isInsideLibrary(key, newPath)) {
          final doc = _pdfCache.remove(key);
          if (doc != null) {
            try {
              await doc.close();
            } catch (_) {}
          }
        }
      }

      return MediaItem(
        id: newPath,
        displayName: fixedName,
        kind: MediaKind.folder,
        folderRaw: item.folderRaw,
        modified: item.modified,
        sizeBytes: item.sizeBytes,
        tags: item.tags,
      );
    }

    final oldFile = File(oldPath);
    if (!await oldFile.exists()) {
      throw Exception('File not found: $oldPath');
    }

    await LocalPathOperationService.renameItem(
      sourcePath: oldPath,
      targetPath: newPath,
      isDirectory: false,
    );

    return MediaItem(
      id: newPath,
      displayName: fixedName,
      kind: item.kind,
      folderRaw: item.folderRaw,
      modified: item.modified,
      sizeBytes: item.sizeBytes,
      tags: item.tags,
    );
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

  @override
  Future<int> importIntoFolder(
    FolderHandle folder, {
    ImportRequest? request,
    void Function(MediaTransferProgress progress)? onProgress,
  }) async {
    final destDir = Directory(folder.raw);
    if (!await destDir.exists()) {
      throw Exception('Folder not found: ${folder.raw}');
    }

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

    final files = await openFiles(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Images/PDF',
          extensions: MediaFileTypes.mediaPickerExtensions,
        ),
      ],
    );

    if (files.isEmpty) return 0;

    final overwriteExisting = !(request?.skipIfExists ?? true);
    int ok = 0;
    int sentBytes = 0;
    final totalFiles = files.length;
    final totalBytes = await _sumFileSelectorBytes(files);
    for (final xf in files) {
      try {
        final src = File(xf.path);
        if (!await src.exists()) continue;

        final name = xf.name;
        final stat = await src.stat();
        final copied = await LocalPathOperationService.copyItem(
          sourcePath: src.path,
          targetPath: '${destDir.path}${Platform.pathSeparator}$name',
          overwrite: overwriteExisting,
        );
        if (!copied) {
          continue;
        }
        ok++;
        sentBytes += stat.size;
        onProgress?.call(
          MediaTransferProgress(
            sentBytes: sentBytes,
            totalBytes: totalBytes,
            completedFiles: ok,
            totalFiles: totalFiles,
            currentFileName: name,
          ),
        );
      } catch (_) {}
    }
    return ok;
  }

  @override
  Future<int> importItemsIntoFolder(
    FolderHandle dest,
    List<MediaItem> items, {
    ImportMetadata? importMetadata,
    bool skipIfExists = true,
    void Function(MediaTransferProgress progress)? onProgress,
  }) async {
    final destDir = Directory(dest.raw);
    if (!await destDir.exists()) {
      await destDir.create(recursive: true);
    }

    int ok = 0;
    int sentBytes = 0;
    final uploadTargets = items
        .where((item) => item.kind != MediaKind.folder)
        .toList(growable: false);
    final totalFiles = uploadTargets.length;
    final totalBytes = uploadTargets.fold<int>(
      0,
      (sum, item) => sum + (item.sizeBytes ?? 0),
    );

    for (final it in items) {
      if (it.kind == MediaKind.folder) continue;

      final src = File(it.id);
      if (!await src.exists()) continue;

      final name = it.displayName;
      final copied = await LocalPathOperationService.copyItem(
        sourcePath: src.path,
        targetPath: '${destDir.path}${Platform.pathSeparator}$name',
        overwrite: !skipIfExists,
      );
      if (!copied) {
        continue;
      }
      ok++;
      sentBytes += it.sizeBytes ?? 0;
      onProgress?.call(
        MediaTransferProgress(
          sentBytes: sentBytes,
          totalBytes: totalBytes,
          completedFiles: ok,
          totalFiles: totalFiles,
          currentFileName: name,
        ),
      );
    }

    return ok;
  }

  Future<int> _sumFileSelectorBytes(List<XFile> files) async {
    var total = 0;
    for (final file in files) {
      try {
        total += await File(file.path).length();
      } catch (_) {}
    }
    return total;
  }
}
