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

  // 簡易メモリキャッシュ（最短版）
  final Map<String, ThumbPair> _thumbCache = {};

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

    final files = <File>[];
    await for (final e in dir.list(recursive: false, followLinks: false)) {
      if (e is File) files.add(e);
    }

    final items = <MediaItem>[];
    for (final f in files) {
      final ext = _lowerExt(f.path);
      MediaKind? kind;
      if (_imageExt.contains(ext)) kind = MediaKind.image;
      if (ext == _pdfExt) kind = MediaKind.pdf;
      if (kind == null) continue;

      final stat = await f.stat();
      items.add(MediaItem(
        id: f.path,
        displayName: _fileName(f.path),
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
    return await File(item.id).readAsBytes();
  }

  @override
  Future<ThumbPair> readThumbPair(MediaItem item, {int maxWidth = 360}) async {
    final cacheKey = '${item.id}|$maxWidth';
    final cached = _thumbCache[cacheKey];
    if (cached != null) return cached;

    late ThumbPair pair;
    if (item.kind == MediaKind.image) {
      final bytes = await File(item.id).readAsBytes();
      // 画像は「表紙のみ」でOK（背後はUI側で同一を使っても良い）
      pair = ThumbPair(front: bytes, back: null);
    } else {
      // PDF: 1ページ目 + 中間ページ
      final doc = await PdfDocument.openFile(item.id);
      final pageCount = doc.pagesCount;
      final mid = (pageCount / 2).ceil().clamp(1, pageCount);

      final front = await _renderPage(doc, 1, maxWidth);
      Uint8List? back;
      if (pageCount >= 2) {
        back = await _renderPage(doc, mid, maxWidth);
      }
      await doc.close();

      pair = ThumbPair(front: front, back: back);
    }

    _thumbCache[cacheKey] = pair;
    return pair;
  }

  Future<Uint8List> _renderPage(PdfDocument doc, int pageNumber, int maxWidth) async {
    final page = await doc.getPage(pageNumber);
    // 縦横比を保ったレンダリング
     final scale = maxWidth / page.width;       // page.width は double
    final double w = maxWidth.toDouble();
    final double h = (page.height * scale);    // double

    final img = await page.render(
      width: w,
      height: h,
      format: PdfPageImageFormat.png,
   );

    await page.close();

    if (img == null) {
      // 万一失敗したら空画像ではなく例外に
      throw Exception('PDF render failed (page=$pageNumber)');
    }
    return img.bytes;
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