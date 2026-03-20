import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';

import '../models/folder.dart';
import '../models/mediaItem.dart';
import 'mediaRepository.dart';

/// ------------------------------
/// LRU メモリキャッシュ（容量/件数制限）
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
    // アクセスされたものを末尾へ
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
    // 件数 or 容量を満たすまで古いものから捨てる
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

class WindowsFolderRepository implements MediaRepository {
  static const _imageExt = <String>{'.jpg', '.jpeg', '.png', '.webp', '.bmp'};
  static const _pdfExt = '.pdf';

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
  // サムネイル：メモリLRUキャッシュ
  // ------------------------------
  // 目安: 64MB / 最大400件
  // （どちらか先に達したら古いものから破棄）
  final _LruCache<String, ThumbPair> _thumbCache = _LruCache<String, ThumbPair>(
    maxBytes: 64 * 1024 * 1024,
    maxEntries: 400,
    sizeOf: (pair) =>
        pair.front.lengthInBytes + (pair.back?.lengthInBytes ?? 0),
  );

  // 同一サムネの同時要求を1回にまとめ、急なスクロールに対応できるように
  final Map<String, Future<ThumbPair>> _thumbInFlight = {};

  // PDF キャッシュ（ページ送り高速化）
  final Map<String, PdfDocument> _pdfCache = {};

  @override
  Future<FolderHandle?> pickFolder() async {
    final path = await getDirectoryPath();
    if (path == null || path.isEmpty) return null;
    return FolderHandle(path);
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
      return _imageExt.contains(ext) || ext == _pdfExt;
    }

    // 表示用は「直下のみ」＋ Directory も返す
    final entries = <FileSystemEntity>[];
    await for (final e in dir.list(recursive: false, followLinks: false)) {
      entries.add(e);
    }

    final total = entries.length;
    int processed = 0;

    final folders = <MediaItem>[];
    final files = <MediaItem>[];

    for (final e in entries) {
      // 直下サブフォルダ
      if (e is Directory) {
        final stat = await e.stat();
        final name = _fileName(e.path); // 既存のヘルパー流用（末尾名取得）

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

      // 直下ファイル（画像/PDF）
      if (!isMediaFile(e)) {
        processed++;
        if (onProgress != null) onProgress(processed, total);
        continue;
      }

      final f = e as File;
      final name = _fileName(f.path);
      final ext = _lowerExt(name);

      final kind = _imageExt.contains(ext) ? MediaKind.image : MediaKind.pdf;
      final stat = await f.stat();

      files.add(
        MediaItem(
          id: f.path,
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

    // 見やすく：フォルダ→ファイル、各々名前順
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
        total++; // フォルダも表示対象
      } else if (ent is File) {
        final name = ent.uri.pathSegments.isNotEmpty
            ? ent.uri.pathSegments.last
            : ent.path;
        if (_isTargetFileName(name)) total++; // 画像/PDFのみ
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

    final folders = <MediaItem>[];
    final files = <MediaItem>[];

    await for (final ent in dir.list(recursive: false, followLinks: false)) {
      if (ent is Directory) {
        final stat = await ent.stat();
        folders.add(
          MediaItem(
            id: ent.path,
            displayName: _fileName(ent.path),
            kind: MediaKind.folder,
            folderRaw: folder.raw,
            modified: stat.modified,
            tags: const [],
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
        final kind = (ext == _pdfExt) ? MediaKind.pdf : MediaKind.image;
        final stat = await ent.stat();

        files.add(
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

    // フォルダ→ファイル、名前順
    folders.sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    files.sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));

    final all = <MediaItem>[...folders, ...files];
    final total = all.length;

    final start = offset.clamp(0, total);
    final end = (start + limit).clamp(0, total);
    final slice = all.sublist(start, end);

    if (onProgress != null) onProgress(slice.length, slice.length);
    return PagedMediaResult(items: slice, total: total);
  }

  @override
  Future<List<MediaItem>> listMediaRecursiveFiles(
    FolderHandle folder, {
    void Function(int processed, int total)? onProgress,
  }) async {
    // Windowsは常にファイルパス前提
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
      items.add(
        MediaItem(
          id: ent.path,
          displayName: name,
          kind: kind,
          folderRaw: folder.raw, // ★検索元ルート
          modified: stat.modified,
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
    return File(item.id).readAsBytes();
  }

  // ---- ページ数を取得 ----
  @override
  Future<int> getPageCount(MediaItem item) async {
    if (item.kind != MediaKind.pdf) return 1;
    final doc = await _openPdf(item.id);
    return doc.pagesCount;
  }

  // ---- 任意ページをPNGとして取得できるように ----
  @override
  Future<Uint8List> renderPageBytes(
    MediaItem item,
    int page, {
    int maxWidth = 1600,
  }) async {
    if (item.kind != MediaKind.pdf) {
      return readBytes(item);
    }

    final doc = await _openPdf(item.id);
    final total = doc.pagesCount;
    final p = page.clamp(1, total);

    return _renderPage(doc, p, maxWidth);
  }

  @override
  Future<ThumbPair> readThumbPair(MediaItem item, {int maxWidth = 360}) async {
    final cacheKey = '${item.id}|$maxWidth';

    // LRU キャッシュをあたってみる
    final cached = _thumbCache.get(cacheKey);
    if (cached != null) return cached;

    // 同一キーの in-flight を共有
    final inflight = _thumbInFlight[cacheKey];
    if (inflight != null) return inflight;

    // 作成（in-flight 登録）
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
      final bytes = await File(item.id).readAsBytes();
      return ThumbPair(front: bytes, back: null);
    }

    // PDF: 1ページ目 + 中間ページ（docキャッシュを利用）
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

    final doc = await PdfDocument.openFile(path);
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

  /// フォルダ切替・アプリ終了時に呼ぶとメモリリークしにくい
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
    return ext == _pdfExt || _imageExt.contains(ext);
  }

  @override
  Future<MediaItem> rename(MediaItem item, String newDisplayName) async {
    final oldPath = item.id;
    final oldFile = File(oldPath);
    if (!await oldFile.exists()) {
      throw Exception('File not found: $oldPath');
    }

    final fixedName = _ensureExtensionForFs(item, newDisplayName);

    final parent = oldFile.parent.path;
    final newPath = '$parent${Platform.pathSeparator}$fixedName';

    final renamed = await oldFile.rename(newPath);

    // ファイルパスは変わるので id も更新する
    return MediaItem(
      id: renamed.path,
      displayName: fixedName,
      kind: item.kind,
      folderRaw: item.folderRaw,
      modified: item.modified,
      tags: item.tags,
    );
  }

  @override
  Future<int> importIntoFolder(FolderHandle folder) async {
    final destDir = Directory(folder.raw);
    if (!await destDir.exists()) {
      throw Exception('Folder not found: ${folder.raw}');
    }

    final files = await openFiles(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Images/PDF',
          extensions: ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'pdf'],
        ),
      ],
    );

    if (files.isEmpty) return 0;

    int ok = 0;
    for (final xf in files) {
      try {
        final src = File(xf.path);
        if (!await src.exists()) continue;

        final name = xf.name;
        final unique = _uniqueNameInDir(destDir, name);
        await src.copy('${destDir.path}${Platform.pathSeparator}$unique');
        ok++;
      } catch (_) {}
    }
    return ok;
  }

    @override
  Future<int> importItemsIntoFolder(
    FolderHandle dest,
    List<MediaItem> items, {
    bool skipIfExists = true,
  }) async {
    final destDir = Directory(dest.raw);
    if (!await destDir.exists()) {
      await destDir.create(recursive: true);
    }

    // 既存名セット（軽量な重複回避）
    final existingLowerNames = <String>{};
    await for (final ent in destDir.list(recursive: false, followLinks: false)) {
      if (ent is File) {
        final name = _fileName(ent.path).toLowerCase();
        existingLowerNames.add(name);
      }
    }

    int ok = 0;

    for (final it in items) {
      if (it.kind == MediaKind.folder) continue;

      final src = File(it.id); // Windowsではid=フルパス
      if (!await src.exists()) continue;

      final name = it.displayName;
      final lower = name.toLowerCase();

      if (skipIfExists && existingLowerNames.contains(lower)) {
        continue; // 同名が既に保管庫にあるのでスキップ
      }

      // 競合する場合は unique 名で保存（skip=false の時の挙動）
      final outName = skipIfExists ? name : _uniqueNameInDir(destDir, name);
      await src.copy('${destDir.path}${Platform.pathSeparator}$outName');
      existingLowerNames.add(outName.toLowerCase());
      ok++;
    }

    return ok;
  }

  String _uniqueNameInDir(Directory dir, String name) {
    final dot = name.lastIndexOf('.');
    final base = dot >= 0 ? name.substring(0, dot) : name;
    final ext = dot >= 0 ? name.substring(dot) : '';

    var candidate = name;
    var n = 1;
    while (File(
      '${dir.path}${Platform.pathSeparator}$candidate',
    ).existsSync()) {
      candidate = '$base ($n)$ext';
      n++;
      if (n > 999) {
        candidate = '${base}_${DateTime.now().millisecondsSinceEpoch}$ext';
        break;
      }
    }
    return candidate;
  }

  String _ensureExtensionForFs(MediaItem item, String name) {
    final n = name.trim();
    if (n.isEmpty) return item.displayName;

    if (item.kind == MediaKind.pdf) {
      return n.toLowerCase().endsWith('.pdf') ? n : '$n.pdf';
    }

    final ext = _extLowerFs(item.displayName);
    if (ext.isEmpty) return n;
    return n.toLowerCase().endsWith(ext) ? n : '$n$ext';
  }

  String _extLowerFs(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot < 0 || dot == fileName.length - 1) return '';
    return fileName.substring(dot).toLowerCase();
  }
}
