import 'dart:collection';
import 'dart:typed_data';

import 'package:shared_storage/shared_storage.dart' as ss;
import 'dart:ui' as ui;
import 'package:pdfx/pdfx.dart';

import '../models/folder.dart';
import '../models/mediaItem.dart';
import 'mediaRepository.dart';

/// NOTE:
/// SAF（Storage Access Framework）経由で treeUri 配下を読む Repository。
/// 実際の SAF API は採用パッケージに合わせて差し替えてください。
class AndroidFolderRepository implements MediaRepository {
  static const _imageExt = <String>{'.jpg', '.jpeg', '.png', '.webp', '.bmp'};
  static const _pdfExt = '.pdf';

  // ------------------------------
  // サムネLRU（Windows版と同等）
  // ------------------------------
  final _LruCache<String, ThumbPair> _thumbCache = _LruCache<String, ThumbPair>(
    maxBytes: 64 * 1024 * 1024,
    maxEntries: 400,
    sizeOf: (pair) =>
        pair.front.lengthInBytes + (pair.back?.lengthInBytes ?? 0),
  );

  final Map<String, Future<ThumbPair>> _thumbInFlight = {};

  // PDF: bytes→doc キャッシュ（同一PDFのページ送りを高速化）
  final Map<String, PdfDocument> _pdfCache = {};

  // ==============================
  // SAF アダプタ（ここだけパッケージ依存）
  // ==============================
  // 例：treeUri をユーザーが選択
  Future<String?> _safPickTreeUri() async {
    // TODO: SAFパッケージの「フォルダ選択」を呼ぶ
    // return await Saf.openDocumentTree();
    return null;
  }

  Future<List<_SafEntry>> _safListRecursive(String treeUri) async {
  final root = Uri.parse(treeUri);

  // 権限が無い/切れてると列挙が空になります
  final canRead = await ss.canRead(root);
  if (canRead != true) return const [];

  const cols = <ss.DocumentFileColumn>[
    ss.DocumentFileColumn.uri,
    ss.DocumentFileColumn.name,
    ss.DocumentFileColumn.isDirectory,
    ss.DocumentFileColumn.lastModified,
    // size/type は重いことがあるので最小限に（必要なら後で足す）
  ];

  final out = <_SafEntry>[];
  final queue = <Uri>[root];

  // BFS でサブフォルダも掘る
  while (queue.isNotEmpty) {
    final dir = queue.removeLast();

    // listFiles は Stream で返る（直下を列挙する想定）
    await for (final f in ss.listFiles(dir, columns: cols)) {
      final name = f.name ?? '';
      if (name.isEmpty) continue;

      final isDir = f.isDirectory == true;

      if (isDir) {
        // サブフォルダを掘る
        queue.add(Uri.parse(f.uri.toString()));
        continue;
      }

      out.add(_SafEntry(
        documentUri: f.uri.toString(),
        name: name,
        modified: f.lastModified,
        isDir: false,
      ));
    }

    // UI 固まり対策：イベントループに一瞬譲る（大量フォルダで効く）
    await Future<void>.delayed(Duration.zero);
  }

  return out;
}

  // 例：documentUri から bytes を読む
  Future<Uint8List> _safReadBytes(String documentUri) async {
    // TODO: SAFパッケージに合わせて実装
    throw UnimplementedError('SAF readBytes not implemented');
  }

  // ==============================
  // MediaRepository
  // ==============================
  @override
  Future<FolderHandle?> pickFolder() async {
    final treeUri = await _safPickTreeUri();
    if (treeUri == null || treeUri.isEmpty) return null;
    return FolderHandle(treeUri);
  }

  @override
Future<List<MediaItem>> listMedia(FolderHandle folder) async {
  final entries = await _safListRecursive(folder.raw);

  // まず列挙数が取れているか確認（実機の logcat に出ます）
  // ignore: avoid_print
  print('[SAF] entries=${entries.length} first=${entries.isNotEmpty ? entries.first.name : "-"}');

  final items = <MediaItem>[];
  for (final e in entries) {
    final lower = e.name.toLowerCase();

    MediaKind? kind;
    if (lower.endsWith('.pdf')) {
      kind = MediaKind.pdf;
    } else if (lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp')) {
      kind = MediaKind.image;
    } else {
      continue;
    }

    items.add(MediaItem(
      id: e.documentUri,
      displayName: e.name,
      kind: kind,
      folderRaw: folder.raw,
      modified: e.modified,
    ));
  }

  // ignore: avoid_print
  print('[SAF] mediaItems=${items.length}');
  return items;
}



  @override
  Future<Uint8List> readBytes(MediaItem item) => _safReadBytes(item.id);

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
    if (item.kind != MediaKind.pdf) return readBytes(item);
    final doc = await _openPdf(item.id);
    final total = doc.pagesCount;
    final p = page.clamp(1, total);
    return _renderPage(doc, p, maxWidth);
  }

  @override
  Future<ThumbPair> readThumbPair(MediaItem item, {int maxWidth = 360}) async {
    final cacheKey = '${item.id}|$maxWidth';

    final cached = _thumbCache.get(cacheKey);
    if (cached != null) return cached;

    final inflight = _thumbInFlight[cacheKey];
    if (inflight != null) return inflight;

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
      final bytes = await readBytes(item);

      final thumb = await _makeImageThumb(bytes, maxWidth);
      return ThumbPair(front: bytes, back: null);
    }

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

  Future<PdfDocument> _openPdf(String documentUri) async {
    final cached = _pdfCache[documentUri];
    if (cached != null) return cached;

    // Android は openFile が使えないため、bytes→openData
    final bytes = await _safReadBytes(documentUri);
    final doc = await PdfDocument.openData(bytes);

    _pdfCache[documentUri] = doc;
    return doc;
  }

  Future<Uint8List> _renderPage(PdfDocument doc, int pageNumber, int maxWidth) async {
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
}

/// SAF から返ってくる1ファイル分の情報（パッケージ依存部分を隔離）
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

/// Windows版から移植（同じ挙動にする）
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
  // 0バイト対策
  if (src.isEmpty) return src;

  final codec = await ui.instantiateImageCodec(
    src,
    targetWidth: targetWidth,
  );
  final frame = await codec.getNextFrame();
  final ui.Image image = frame.image;

  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  if (byteData == null) return src;

  return byteData.buffer.asUint8List();
}
