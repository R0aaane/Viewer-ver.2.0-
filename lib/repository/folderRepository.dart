import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
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
    // アクセスされたものを末尾へ（最近使った）
    _map[key] = v;
    return v;
  }

  void put(K key, V value) {
    // 既存があれば差し替え（容量調整）
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

  // ------------------------------
  // サムネイル：メモリLRUキャッシュ
  // ------------------------------
  // 目安: 64MB / 最大400件（どちらか先に達したら古いものから破棄）
  final _LruCache<String, ThumbPair> _thumbCache = _LruCache<String, ThumbPair>(
    maxBytes: 64 * 1024 * 1024,
    maxEntries: 400,
    sizeOf: (pair) =>
        pair.front.lengthInBytes + (pair.back?.lengthInBytes ?? 0),
  );

  // 同一サムネの同時要求を1回にまとめる（急スクロール対策）
  final Map<String, Future<ThumbPair>> _thumbInFlight = {};

  // PDF document キャッシュ（ページ送り高速化）
  final Map<String, PdfDocument> _pdfCache = {};

  @override
  Future<FolderHandle?> pickFolder() async {
    final path = await getDirectoryPath();
    if (path == null || path.isEmpty) return null;
    return FolderHandle(path);
  }

  @override
  Future<List<MediaItem>> listMedia(FolderHandle folder) async {
    final dir = Directory(folder.raw);
    if (!await dir.exists()) return const [];

    final items = <MediaItem>[];
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;

      final ext = _lowerExt(e.path);

      MediaKind? kind;
      if (_imageExt.contains(ext)) {
        kind = MediaKind.image;
      } else if (ext == _pdfExt) {
        kind = MediaKind.pdf;
      } else {
        continue;
      }

      final stat = await e.stat();

      items.add(
        MediaItem(
          id: e.path, // ★フルパス
          displayName: _fileName(e.path),
          kind: kind,
          folderRaw: folder.raw,
          modified: stat.modified,
        ),
      );
    }

    // 更新日時 新しい順
    items.sort((a, b) {
      final am = a.modified?.millisecondsSinceEpoch ?? 0;
      final bm = b.modified?.millisecondsSinceEpoch ?? 0;
      return bm.compareTo(am);
    });

    return items;
  }

  @override
  Future<Uint8List> readBytes(MediaItem item) async {
    return File(item.id).readAsBytes();
  }

  // ---- 追加：ページ数取得 ----
  @override
  Future<int> getPageCount(MediaItem item) async {
    if (item.kind != MediaKind.pdf) return 1;
    final doc = await _openPdf(item.id);
    return doc.pagesCount;
  }

  // ---- 追加：任意ページをPNGとして取得（画像はそのまま返す）----
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

    // 1) LRU キャッシュ hit
    final cached = _thumbCache.get(cacheKey);
    if (cached != null) return cached;

    // 2) 同一キーの in-flight を共有
    final inflight = _thumbInFlight[cacheKey];
    if (inflight != null) return inflight;

    // 3) 作成（in-flight 登録）
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

  String _uniqueNameInDir(Directory dir, String name) {
    final dot = name.lastIndexOf('.');
    final base = dot >= 0 ? name.substring(0, dot) : name;
    final ext = dot >= 0 ? name.substring(dot) : '';

    var candidate = name;
    var n = 1;
    while (File('${dir.path}${Platform.pathSeparator}$candidate').existsSync()) {
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
