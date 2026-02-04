import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:pdfx/pdfx.dart';

import '../models/folder.dart';
import '../models/mediaItem.dart';
import 'mediaRepository.dart';

class WindowsFolderRepository implements MediaRepository {
  static const _imageExt = <String>{'.jpg', '.jpeg', '.png', '.webp', '.bmp'};
  static const _pdfExt = '.pdf';

  // 一覧サムネ用キャッシュ
  final Map<String, ThumbPair> _thumbCache = {};

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

      items.add(MediaItem(
        id: e.path, // ★フルパス
        displayName: _fileName(e.path),
        kind: kind,
        modified: stat.modified,
      ));
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
    final cached = _thumbCache[cacheKey];
    if (cached != null) return cached;

    late ThumbPair pair;

    if (item.kind == MediaKind.image) {
      final bytes = await File(item.id).readAsBytes();
      pair = ThumbPair(front: bytes, back: null);
    } else {
      // PDF: 1ページ目 + 中間ページ（docキャッシュを利用）
      final doc = await _openPdf(item.id);
      final pageCount = doc.pagesCount;
      final mid = (pageCount / 2).ceil().clamp(1, pageCount);

      final front = await _renderPage(doc, 1, maxWidth);
      Uint8List? back;
      if (pageCount >= 2) {
        back = await _renderPage(doc, mid, maxWidth);
      }
      pair = ThumbPair(front: front, back: back);
    }

    _thumbCache[cacheKey] = pair;
    return pair;
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
  Future<Uint8List> _renderPage(PdfDocument doc, int pageNumber, int maxWidth) async {
  final page = await doc.getPage(pageNumber);

  final scale = maxWidth / page.width;   // page.width は double
  final double w = maxWidth.toDouble();  // ★ double にする
  final double h = (page.height * scale); // ★ double のまま

  final img = await page.render(
    width: w,   // ★ double
    height: h,  // ★ double
    format: PdfPageImageFormat.png,
  );

  await page.close();

  if (img == null) {
    throw Exception('PDF render failed (page=$pageNumber)');
  }
    return img.bytes;
  }

  /// 任意：フォルダ切替・アプリ終了時に呼ぶとメモリリークしにくい
  Future<void> dispose() async {
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
}
