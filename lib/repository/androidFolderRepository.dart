import 'dart:async';
import 'dart:io';
import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:docman/docman.dart';
import 'package:pdfx/pdfx.dart';
import 'package:path_provider/path_provider.dart';

import '../models/folder.dart';
import '../models/mediaItem.dart';
import 'mediaRepository.dart';

class AndroidFolderRepository implements MediaRepository {
  static const _imageExt = <String>{'.jpg', '.jpeg', '.png', '.webp', '.bmp'};
  static const _pdfExt = '.pdf';

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
    final dir = await DocumentFile.fromUri(dirUri);
    if (dir == null) return const [];
    if (dir.isDirectory != true) return const [];

    final children = await dir.listDocuments();

    final out = <_SafEntry>[];
    for (final f in children) {
      final name = f.name;
      if (name.isEmpty) continue;

      out.add(
        _SafEntry(
          documentUri: f.uri,
          name: name,
          modified: _toDateTimeSafe(f.lastModified),
          isDir: f.isDirectory == true,
        ),
      );
    }
    return out;
  }


  Future<Uint8List> _safReadBytes(String documentUri) async {
    final doc = await DocumentFile.fromUri(documentUri);
    if (doc == null) {
      throw Exception('DocumentFile.fromUri failed: $documentUri');
    }
    if (doc.isDirectory == true) {
      throw Exception('Tried to read directory as file: $documentUri');
    }

    // 1) まず read()
    final cached = await doc.cache();
    if (cached == null) {
      throw Exception('cache() failed: $documentUri');
    }

    final fb = await cached.readAsBytes();
    if (fb.isEmpty) {
      throw Exception('cached file is empty: $documentUri');
    }
    return fb;
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
  Future<List<MediaItem>> listMedia(FolderHandle folder) async {
    final raw = folder.raw;

    // ★ content:// は SAF、それ以外は通常ファイルパス（保管庫など）
    if (raw.startsWith('content://')) {
      return _listMediaSaf(folder);
    } else {
      return _listMediaFs(folder);
    }
  }

  Future<List<MediaItem>> _listMediaSaf(FolderHandle folder) async {
    final entries = await _safListRecursive(folder.raw);
    final items = <MediaItem>[];
    for (final e in entries) {
      final ext = _lowerExt(e.name);

      MediaKind? kind;
      if (ext == _pdfExt) {
        kind = MediaKind.pdf;
      } else if (_imageExt.contains(ext)) {
        kind = MediaKind.image;
      }
      if (kind == null) continue;

      items.add(MediaItem(
        id: e.documentUri,
        displayName: e.name,
        kind: kind,
        folderRaw: folder.raw,
        modified: e.modified,
        tags: const [],
      ));
    }
    return items;
  }

  Future<List<MediaItem>> _listMediaFs(FolderHandle folder) async {
    final dir = Directory(folder.raw);
    if (!await dir.exists()) return const [];

    final items = <MediaItem>[];
    await for (final ent in dir.list(recursive: true, followLinks: false)) {
      if (ent is! File) continue;
      final name = ent.uri.pathSegments.isNotEmpty ? ent.uri.pathSegments.last : ent.path;
      final ext = _lowerExt(name);

      MediaKind? kind;
      if (ext == _pdfExt) {
        kind = MediaKind.pdf;
      } else if (_imageExt.contains(ext)) {
        kind = MediaKind.image;
      }
      if (kind == null) continue;

      final stat = await ent.stat();
      items.add(MediaItem(
        id: ent.path, // ★ 内部保管庫は file path を id として使う
        displayName: name,
        kind: kind,
        folderRaw: folder.raw,
        modified: stat.modified,
        tags: const [],
      ));
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
    if (item.kind != MediaKind.pdf) return readBytes(item);
    final doc = await _openPdf(item.id);
    final total = doc.pagesCount;
    final p = page.clamp(1, total);
    return _renderPage(item.id, doc, p, maxWidth);
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
      return ThumbPair(front: thumb, back: null);
    }

    final doc = await _openPdf(item.id);
    final pageCount = doc.pagesCount;
    final mid = (pageCount / 2).ceil().clamp(1, pageCount);

    final front = await _renderPage(item.id, doc, 1, maxWidth);
    Uint8List? back;
    if (pageCount >= 2) {
      back = await _renderPage(item.id, doc, mid, maxWidth);
    }
    return ThumbPair(front: front, back: back);
  }

  Future<PdfDocument> _openPdf(String documentUri) {
    return _lockOf(documentUri).synchronized(() async {
      final cached = _pdfCache.remove(documentUri);
      if (cached != null) {
        _pdfCache[documentUri] = cached; // LRU更新
        return cached;
      }

      PdfDocument doc;

      // ★ SAF (content://...) と、保管庫 (file path) を分岐
      if (documentUri.startsWith('content://')) {
        // SAF: cache() してから openFile
        final docFile = await DocumentFile.fromUri(documentUri);
        if (docFile == null) {
          throw Exception('DocumentFile.fromUri failed: $documentUri');
        }
        final cachedFile = await docFile.cache();
        if (cachedFile == null) {
          throw Exception('cache() failed: $documentUri');
        }
        doc = await PdfDocument.openFile(cachedFile.path);
      } else {
        // 保管庫など: そのままファイルパスで openFile
        final f = File(documentUri);
        if (!await f.exists()) {
          throw Exception('PDF file not found: $documentUri');
        }
        doc = await PdfDocument.openFile(documentUri);
      }

      _pdfCache[documentUri] = doc;

      while (_pdfCache.length > _pdfCacheMaxEntries) {
        final oldestKey = _pdfCache.keys.first;
        final oldest = _pdfCache.remove(oldestKey);
        if (oldest != null) {
          await oldest.close();
        }
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

  @override
  Future<MediaItem> rename(MediaItem item, String newDisplayName) async {
    if (item.kind != MediaKind.pdf) {
      throw Exception('rename: only pdf is supported now');
    }

    final src = await DocumentFile.fromUri(item.id);
    if (src == null) {
      throw Exception('rename: src not found: ${item.id}');
    }

    final dir = await DocumentFile.fromUri(item.folderRaw);
    if (dir == null || dir.isDirectory != true) {
      throw Exception('rename: parent dir not found: ${item.folderRaw}');
    }

    final fixedName = _ensurePdfName(newDisplayName);

    // ✅ moveTo で同一フォルダに移動（=リネーム）
    // docmanのバージョン差を吸収するため dynamic で呼ぶ
    final d = src as dynamic;

    DocumentFile? moved;

    // パターン1: moveTo(DocumentFile dir, {String? newName})
    try {
      final r = await d.moveTo(dir, newName: fixedName);
      if (r is DocumentFile) moved = r;
    } catch (_) {}

    // パターン2: moveTo(DocumentFile dir, {String? name})
    if (moved == null) {
      try {
        final r = await d.moveTo(dir, name: fixedName);
        if (r is DocumentFile) moved = r;
      } catch (_) {}
    }

    // パターン3: moveTo({required DocumentFile dir, required String newName})
    if (moved == null) {
      try {
        final r = await d.moveTo(dir: dir, newName: fixedName);
        if (r is DocumentFile) moved = r;
      } catch (_) {}
    }

    if (moved == null) {
      throw Exception('rename: moveTo not supported or permission denied');
    }

    // id(uri)は変わる可能性あり（今は気にしないとのことなのでここでは反映のみ）
    return MediaItem(
      id: moved.uri,
      displayName: fixedName,
      kind: item.kind,
      folderRaw: item.folderRaw,
      modified: DateTime.now(),
      tags: item.tags,
    );
  }

  String _ensurePdfName(String name) {
    final n = name.trim();
    if (n.isEmpty) return 'export.pdf';
    return n.toLowerCase().endsWith('.pdf') ? n : '$n.pdf';
  }

  Future<List<_SafEntry>> _safListRecursive(String treeUri) async {
  final root = await DocumentFile.fromUri(treeUri);
  if (root == null) return const [];
  if (root.isDirectory != true) return const [];

  final out = <_SafEntry>[];
  final queue = <DocumentFile>[root];

  while (queue.isNotEmpty) {
    final dir = queue.removeLast();
    final children = await dir.listDocuments();

    for (final f in children) {
      final name = f.name ?? '';
      if (name.isEmpty) continue;

      final isDir = f.isDirectory == true;
      if (isDir) {
        queue.add(f);
        continue;
      }

      out.add(_SafEntry(
        documentUri: f.uri,
        name: name,
        modified: _toDateTimeSafe(f.lastModified),
        isDir: false,
      ));
    }

    await Future<void>.delayed(Duration.zero);
  }

  return out;
}

  

  // -------------------------
  // SAF: 親フォルダとファイルを探す
  // -------------------------
  Future<(DocumentFile, DocumentFile)?> _findParentAndDoc(
      String treeUri,
      String documentUri,
      ) async {
    final root = await DocumentFile.fromUri(treeUri);
    if (root == null) return null;
    if (root.isDirectory != true) return null;

    final queue = <DocumentFile>[root];

    while (queue.isNotEmpty) {
      final dir = queue.removeLast();
      final children = await dir.listDocuments();

      for (final c in children) {
        if (c.isDirectory == true) {
          queue.add(c);
          continue;
        }
        if (c.uri == documentUri) {
          return (dir, c);
        }
      }

      await Future<void>.delayed(Duration.zero);
    }

    return null;
  }

  @override
  Future<int> importIntoFolder(FolderHandle folder) async {
    final picked = await DocMan.pick.files(
      extensions: const ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'pdf'],
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
    final dir = await DocumentFile.fromUri(folder.raw);
    if (dir == null) {
      throw Exception('DocumentFile.fromUri failed: ${folder.raw}');
    }
    if (dir.isDirectory != true) {
      throw Exception('Target is not a directory: ${folder.raw}');
    }

    if (dir.canCreate == true) {
      int ok = 0;
      for (final f in picked) {
        try {
          final name = f.path.split('/').last;
          final bytes = await f.readAsBytes();
          if (bytes.isEmpty) continue;

        final unique = await _uniqueName(dir, name);
        final created = await dir.createFile(name: unique, bytes: bytes);
        if (created != null) ok++;
      } catch (_) {}
    }
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
      if (n > 999) return '${base}_${DateTime.now().millisecondsSinceEpoch}$ext';
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

  Future<void> _deleteDoc(DocumentFile doc) async {
    final d = doc as dynamic;

    // パターン1: delete()
    try {
      await d.delete();
      return;
    } catch (_) {}

    // パターン2: deleteDocument()
    try {
      await d.deleteDocument();
      return;
    } catch (_) {}

    throw Exception('delete not supported by your docman DocumentFile');
  }

  String _mimeFor({required String itemExt}) {
    if (itemExt == '.pdf') return 'application/pdf';
    if (itemExt == '.png') return 'image/png';
    if (itemExt == '.webp') return 'image/webp';
    if (itemExt == '.bmp') return 'image/bmp';
    return 'image/jpeg'; // jpg/jpeg fallback
  }

  String _ensureExtension(MediaItem item, String name) {
    final n = name.trim();
    if (n.isEmpty) return item.displayName;

    if (item.kind == MediaKind.pdf) {
      return n.toLowerCase().endsWith('.pdf') ? n : '$n.pdf';
    }

    final ext = _lowerExt(item.displayName); // 既存の拡張子を維持
    if (ext.isEmpty) return n;
    return n.toLowerCase().endsWith(ext) ? n : '$n$ext';
  }

  String _extLower(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot < 0 || dot == fileName.length - 1) return '';
    return fileName.substring(dot).toLowerCase();
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
