import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';

import '../media_file_types.dart';
import '../models/folder.dart';
import '../models/mediaItem.dart';
import '../models/metadata_settings.dart';
import '../services/item_name_service.dart';
import '../services/import_source_normalizer.dart';
import '../services/local_path_operation_service.dart';
import '../services/url_import_downloader_service.dart';
import 'mediaRepository.dart';

/// ------------------------------
/// LRU 郢晢ｽ｡郢晢ｽ｢郢晢ｽｪ郢ｧ・ｭ郢晢ｽ｣郢昴・縺咏ｹ晢ｽ･繝ｻ莠･・ｮ・ｹ鬩･繝ｻ闔会ｽｶ隰ｨ・ｰ陋ｻ・ｶ鬮ｯ謦ｰ・ｼ繝ｻ/// ------------------------------
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
    // 郢ｧ・｢郢ｧ・ｯ郢ｧ・ｻ郢ｧ・ｹ邵ｺ霈費ｽ檎ｸｺ貅假ｽらｸｺ・ｮ郢ｧ蜻亥ｿｰ陝・ｽｾ邵ｺ・ｸ
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
    // 莉ｶ謨ｰ or 螳ｹ驥上ｒ貅縺溘☆縺ｾ縺ｧ蜿､縺・ｂ縺ｮ縺九ｉ謐ｨ縺ｦ繧・
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

  const _FsPageEntry({
    required this.path,
    required this.name,
    required this.kind,
  });
}

class WindowsFolderRepository implements MediaRepository {
  static const _pdfExt = '.pdf';

  final UrlImportDownloaderService _urlImportDownloader =
      UrlImportDownloaderService();

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

  @override
  Future<FolderHandle> getAppLibraryFolder() async {
    final base = await getApplicationDocumentsDirectory();
    final libDir = Directory('${base.path}${Platform.pathSeparator}library');
    if (!await libDir.exists()) {
      await libDir.create(recursive: true);
    }
    return FolderHandle(libDir.path);
  }

  // ------------------------------
  // 郢ｧ・ｵ郢晢｣ｰ郢晞亂縺・ｹ晢ｽｫ繝ｻ螢ｹﾎ鍋ｹ晢ｽ｢郢晢ｽｪLRU郢ｧ・ｭ郢晢ｽ｣郢昴・縺咏ｹ晢ｽ･
  // ------------------------------
  // 騾ｶ・ｮ陞ｳ繝ｻ 64MB / 隴崢陞滂ｽｧ400闔会ｽｶ
  // ・医←縺｡繧峨°蜈医↓驕斐＠縺溘ｉ蜿､縺・ｂ縺ｮ縺九ｉ遐ｴ譽・ｼ・
  final _LruCache<String, ThumbPair> _thumbCache = _LruCache<String, ThumbPair>(
    maxBytes: 64 * 1024 * 1024,
    maxEntries: 400,
    sizeOf: (pair) =>
        pair.front.lengthInBytes + (pair.back?.lengthInBytes ?? 0),
  );

  // 陷ｷ蠕｡・ｸﾂ郢ｧ・ｵ郢晢｣ｰ郢晞亂繝ｻ陷ｷ譴ｧ蜃ｾ髫補扱・ｱ繧・ｽ・陜玲ｧｭ竊鍋ｸｺ・ｾ邵ｺ・ｨ郢ｧ竏堋竏ｵﾂ・･邵ｺ・ｪ郢ｧ・ｹ郢ｧ・ｯ郢晢ｽｭ郢晢ｽｼ郢晢ｽｫ邵ｺ・ｫ陝・ｽｾ陟｢諛翫堤ｸｺ髦ｪ・狗ｹｧ蛹ｻ竕ｧ邵ｺ・ｫ
  final Map<String, Future<ThumbPair>> _thumbInFlight = {};

  // PDF 繧ｭ繝｣繝・す繝･・医・繝ｼ繧ｸ騾√ｊ鬮倬溷喧・・
  final Map<String, PdfDocument> _pdfCache = {};

  bool _isUncPath(String path) => path.startsWith(r'\\');

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
      return MediaFileTypes.imageExtensions.contains(ext) || ext == _pdfExt;
    }

    // 髯ｦ・ｨ驕会ｽｺ騾包ｽｨ邵ｺ・ｯ邵ｲ讙主ｳｩ闕ｳ荵昴・邵ｺ・ｿ邵ｲ謳ｾ・ｼ繝ｻDirectory 郢ｧ繧奇ｽｿ譁絶・
    final entries = <FileSystemEntity>[];
    await for (final e in dir.list(recursive: false, followLinks: false)) {
      entries.add(e);
    }

    final total = entries.length;
    int processed = 0;

    final folders = <MediaItem>[];
    final files = <MediaItem>[];

    for (final e in entries) {
      // 騾ｶ・ｴ闕ｳ荵昴＠郢晄じ繝ｵ郢ｧ・ｩ郢晢ｽｫ郢敖
      if (e is Directory) {
        final stat = await e.stat();
        final name = _fileName(
          e.path,
        ); // 隴鯉ｽ｢陝・･繝ｻ郢晏･ﾎ晉ｹ昜ｻ｣繝ｻ雎ｬ竏ｫ逡代・蝓溷ｿｰ陝・ｽｾ陷ｷ讎雁徐陟墓圜・ｼ繝ｻ
        folders.add(
          MediaItem(
            id: e.path,
            displayName: name,
            kind: MediaKind.folder,
            folderRaw: folder.raw,
            modified: stat.modified,
            tags: const [],
          ),
        );

        processed++;
        if (onProgress != null) onProgress(processed, total);
        continue;
      }

      // 逶ｴ荳九ヵ繧｡繧､繝ｫ・育判蜒・PDF・・
      if (!isMediaFile(e)) {
        processed++;
        if (onProgress != null) onProgress(processed, total);
        continue;
      }

      final f = e as File;
      final name = _fileName(f.path);
      final ext = _lowerExt(name);

      final kind = MediaFileTypes.imageExtensions.contains(ext)
          ? MediaKind.image
          : MediaKind.pdf;
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

    // 隕九ｄ縺吶￥・壹ヵ繧ｩ繝ｫ繝竊偵ヵ繧｡繧､繝ｫ縲∝推縲・錐蜑埼・
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
        total++; // 郢晁ｼ斐°郢晢ｽｫ郢敖郢ｧ繧奇ｽ｡・ｨ驕会ｽｺ陝・ｽｾ髮趣ｽ｡
      } else if (ent is File) {
        final name = ent.uri.pathSegments.isNotEmpty
            ? ent.uri.pathSegments.last
            : ent.path;
        if (_isTargetFileName(name)) total++; // 騾包ｽｻ陷偵・PDF邵ｺ・ｮ邵ｺ・ｿ
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
        entries.add(
          _FsPageEntry(
            path: ent.path,
            name: _fileName(ent.path),
            kind: MediaKind.folder,
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
        entries.add(
          _FsPageEntry(
            path: ent.path,
            name: name,
            kind: (ext == _pdfExt) ? MediaKind.pdf : MediaKind.image,
          ),
        );
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
            modified: stat.modified,
            tags: const [],
          ),
        );
      } else {
        final stat = await _withFsRetry(
          entry.path,
          () => File(entry.path).stat(),
        );
        items.add(
          MediaItem(
            id: entry.path,
            displayName: entry.name,
            kind: entry.kind,
            folderRaw: folder.raw,
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
    // Windows邵ｺ・ｯ陝ｶ・ｸ邵ｺ・ｫ郢晁ｼ斐＜郢ｧ・､郢晢ｽｫ郢昜ｻ｣縺幄恆閧ｴ鄂ｲ
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
      return ext == _pdfExt || MediaFileTypes.imageExtensions.contains(ext);
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

      MediaKind? kind;
      if (ext == _pdfExt) kind = MediaKind.pdf;
      if (MediaFileTypes.imageExtensions.contains(ext)) kind = MediaKind.image;
      if (kind == null) continue;

      final stat = await ent.stat();
      items.add(
        MediaItem(
          id: ent.path,
          displayName: name,
          kind: kind,
          folderRaw: folder.raw, // 笘・､懃ｴ｢蜈・Ν繝ｼ繝・
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
  Future<Uint8List> readBytes(MediaItem item) async {
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
    if (_isAvifPath(item.id) || _isAvifPath(item.displayName)) {
      return renderPageBytes(item, 1, maxWidth: maxWidth);
    }
    return readBytes(item);
  }

  bool _isAvifPath(String path) => _lowerExt(path) == '.avif';

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

  // ---- 郢晏｣ｹ繝ｻ郢ｧ・ｸ隰ｨ・ｰ郢ｧ雋槫徐陟輔・----
  @override
  Future<int> getPageCount(MediaItem item) async {
    if (item.kind != MediaKind.pdf) return 1;
    final doc = await _openPdf(item.id);
    return doc.pagesCount;
  }

  // ---- 闔会ｽｻ隲｢荳翫・郢晢ｽｼ郢ｧ・ｸ郢ｧ蜊朗G邵ｺ・ｨ邵ｺ蜉ｱ窶ｻ陷ｿ髢・ｾ蜉ｱ縲堤ｸｺ髦ｪ・狗ｹｧ蛹ｻ竕ｧ邵ｺ・ｫ ----
  @override
  Future<Uint8List> renderPageBytes(
    MediaItem item,
    int page, {
    int maxWidth = 1600,
  }) async {
    if (item.kind != MediaKind.pdf) {
      return _readImageBytesForDisplay(item, maxWidth: maxWidth);
    }

    final doc = await _openPdf(item.id);
    final total = doc.pagesCount;
    final p = page.clamp(1, total);

    return _renderPage(doc, p, maxWidth);
  }

  @override
  Future<ThumbPair> readThumbPair(MediaItem item, {int maxWidth = 360}) async {
    final cacheKey = '${item.id}|$maxWidth';

    // LRU 繧ｭ繝｣繝・す繝･繧偵≠縺溘▲縺ｦ縺ｿ繧・
    final cached = _thumbCache.get(cacheKey);
    if (cached != null) return cached;

    // 蜷御ｸ繧ｭ繝ｼ縺ｮ in-flight 繧貞・譛・
    final inflight = _thumbInFlight[cacheKey];
    if (inflight != null) return inflight;

    // 菴懈・・・n-flight 逋ｻ骭ｲ・・
    final future = _buildThumbPair(item, maxWidth)
        .then((pair) {
          _thumbCache.put(cacheKey, pair);
          return pair;
        })
        .whenComplete(() {
          _thumbInFlight.remove(cacheKey);
        });

    _thumbInFlight[cacheKey] = future;
    return future;
  }

  Future<ThumbPair> _buildThumbPair(MediaItem item, int maxWidth) async {
    if (item.kind == MediaKind.image) {
      final bytes = await _withFsRetry(
        item.id,
        () => File(item.id).readAsBytes(),
      );
      if (_isAvifPath(item.id)) {
        try {
          final thumb = await _makeImageThumb(bytes, maxWidth);
          return ThumbPair(front: thumb, back: null);
        } catch (_) {
          return ThumbPair(front: bytes, back: null);
        }
      }
      return ThumbPair(front: bytes, back: null);
    }

    // PDF: 1繝壹・繧ｸ逶ｮ + 荳ｭ髢薙・繝ｼ繧ｸ・・oc繧ｭ繝｣繝・す繝･繧貞茜逕ｨ・・
    final doc = await _openPdf(item.id);
    final pageCount = doc.pagesCount;
    final mid = (pageCount / 2).ceil().clamp(1, pageCount);

    final front = await _renderPage(doc, 1, maxWidth);
    Uint8List? back;
    if (pageCount >= 2) {
      back = await _renderPage(doc, mid, maxWidth);
    }
    return ThumbPair(front: front, back: back);
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

  /// 郢晁ｼ斐°郢晢ｽｫ郢敖陋ｻ繝ｻ蟠帷ｹ晢ｽｻ郢ｧ・｢郢晏干ﾎ憺お繧・ｽｺ繝ｻ蜃ｾ邵ｺ・ｫ陷ｻ・ｼ邵ｺ・ｶ邵ｺ・ｨ郢晢ｽ｡郢晢ｽ｢郢晢ｽｪ郢晢ｽｪ郢晢ｽｼ郢ｧ・ｯ邵ｺ蜉ｱ竊鍋ｸｺ荳奇ｼ・
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
    return ext == _pdfExt || MediaFileTypes.imageExtensions.contains(ext);
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
      kind: ext == _pdfExt ? MediaKind.pdf : MediaKind.image,
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
