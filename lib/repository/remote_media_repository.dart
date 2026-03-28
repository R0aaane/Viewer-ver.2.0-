import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';

import '../models/folder.dart';
import '../models/mediaItem.dart';
import '../models/metadata_settings.dart';
import '../services/app_settings_service.dart';
import '../services/media_id_resolver.dart';
import '../services/remote_media_api_client.dart';
import 'mediaRepository.dart';

class RemoteMediaRepository implements MediaRepository {
  static final p.Context _winPath = p.Context(style: p.Style.windows);

  final RemoteMediaApiClient _client;
  final MediaRepository _localPickerRepository;
  final MediaIdResolver _idResolver = MediaIdResolver();

  final Map<String, Future<ThumbPair>> _thumbInFlight =
      <String, Future<ThumbPair>>{};
  final Map<String, Future<File>> _downloadInFlight = <String, Future<File>>{};
  final LinkedHashMap<String, PdfDocument> _pdfCache =
      LinkedHashMap<String, PdfDocument>();
  final Map<String, Future<RemoteMediaMeta>> _metaInFlight =
      <String, Future<RemoteMediaMeta>>{};
  final Map<String, RemoteMediaMeta> _metaCache = <String, RemoteMediaMeta>{};

  Directory? _cacheRoot;

  RemoteMediaRepository({
    required String baseUrl,
    String? authToken,
    required MediaRepository localPickerRepository,
  }) : _localPickerRepository = localPickerRepository,
       _client = RemoteMediaApiClient(
         baseUrl: baseUrl,
         authToken: authToken,
       );

  factory RemoteMediaRepository.fromSettings(
    MetadataSettings settings, {
    required MediaRepository localPickerRepository,
  }) {
    return RemoteMediaRepository(
      baseUrl: settings.remoteApiBaseUrl,
      authToken: settings.authToken,
      localPickerRepository: localPickerRepository,
    );
  }

  @override
  AppMode get appMode => AppMode.client;

  @override
  bool get isRemoteMode => true;

  @override
  bool get isHostMode => false;

  @override
  Future<void> reloadSettings() async {}

  @override
  Future<List<FolderHandle>> listAvailableFolders() async {
    if (!_client.isConfigured) {
      return const <FolderHandle>[];
    }
    return _client.listAvailableFolders();
  }

  Future<Directory> _ensureCacheRoot() async {
    final existing = _cacheRoot;
    if (existing != null) {
      return existing;
    }
    final base = await getTemporaryDirectory();
    final dir = Directory(p.join(base.path, 'remote_media_cache'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _cacheRoot = dir;
    return dir;
  }

  Future<Directory> _ensureCacheSubdir(String name) async {
    final root = await _ensureCacheRoot();
    final dir = Directory(p.join(root.path, name));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<RemoteMediaMeta> _metaForItem(MediaItem item) async {
    final mediaId = await _stableMediaId(item);
    final cached = _metaCache[mediaId];
    if (cached != null) {
      return cached;
    }
    final inFlight = _metaInFlight[mediaId];
    if (inFlight != null) {
      return inFlight;
    }
    final future = _client.fetchMediaMeta(mediaId).then((meta) {
      _metaCache[mediaId] = meta;
      _metaInFlight.remove(mediaId);
      return meta;
    });
    _metaInFlight[mediaId] = future;
    return future;
  }

  Future<String> _stableMediaId(MediaItem item) async {
    final identity = await _idResolver.resolve(item);
    return identity.stableId;
  }

  String _cacheHash(String source) {
    var hash = 0x811C9DC5;
    const prime = 0x01000193;
    for (final unit in source.codeUnits) {
      hash ^= unit;
      hash = (hash * prime) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  String _extensionForMeta(RemoteMediaMeta meta) {
    final ext = _winPath.extension(meta.displayName);
    if (ext.isNotEmpty) {
      return ext;
    }
    if (meta.kind == 'pdf') {
      return '.pdf';
    }
    if (meta.mimeType == 'image/png') {
      return '.png';
    }
    if (meta.mimeType == 'image/webp') {
      return '.webp';
    }
    return '.jpg';
  }

  Future<File> _ensureCachedMediaFile(MediaItem item) async {
    final mediaId = await _stableMediaId(item);
    final meta = await _metaForItem(item);
    final fileDir = await _ensureCacheSubdir('files');
    final etagKey =
        (meta.etag == null || meta.etag!.isEmpty)
        ? 'noetag'
        : _cacheHash(meta.etag!);
    final fileName =
        '${_cacheHash(mediaId)}_$etagKey${_extensionForMeta(meta)}';
    final file = File(p.join(fileDir.path, fileName));
    if (await file.exists()) {
      return file;
    }

    final inFlight = _downloadInFlight[file.path];
    if (inFlight != null) {
      return inFlight;
    }

    final future = _client
        .downloadMediaToFile(mediaId, file)
        .then((_) async {
          await _trimCacheDirectory(fileDir, maxEntries: 48);
          _downloadInFlight.remove(file.path);
          return file;
        })
        .catchError((Object error) {
          _downloadInFlight.remove(file.path);
          throw error;
        });

    _downloadInFlight[file.path] = future;
    return future;
  }

  Future<void> _trimCacheDirectory(
    Directory dir, {
    required int maxEntries,
  }) async {
    final children =
        await dir.list().where((entity) => entity is File).cast<File>().toList();
    if (children.length <= maxEntries) {
      return;
    }
    children.sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));
    final removeCount = children.length - maxEntries;
    for (var index = 0; index < removeCount; index++) {
      try {
        await children[index].delete();
      } catch (_) {}
    }
  }

  Future<PdfDocument> _openCachedPdf(MediaItem item) async {
    final file = await _ensureCachedMediaFile(item);
    final cached = _pdfCache.remove(file.path);
    if (cached != null) {
      _pdfCache[file.path] = cached;
      return cached;
    }

    final doc = await PdfDocument.openFile(file.path);
    _pdfCache[file.path] = doc;
    while (_pdfCache.length > 6) {
      final oldestKey = _pdfCache.keys.first;
      final oldest = _pdfCache.remove(oldestKey);
      if (oldest != null) {
        try {
          await oldest.close();
        } catch (_) {}
      }
    }
    return doc;
  }

  Future<Uint8List> _renderPdfPage(
    PdfDocument doc,
    int pageNumber,
    int maxWidth,
  ) async {
    final page = await doc.getPage(pageNumber);
    final scale = maxWidth / page.width;
    final image = await page.render(
      width: maxWidth.toDouble(),
      height: page.height * scale,
      format: PdfPageImageFormat.png,
    );
    await page.close();
    if (image == null) {
      throw const RemoteMediaException('PDF ページの描画に失敗しました');
    }
    return image.bytes;
  }

  MediaItem _toMediaItem(RemoteFolderEntry entry) {
    final rawId = entry.fullPath ?? entry.mediaId ?? entry.entryId;
    final kind = switch (entry.kind) {
      'folder' => MediaKind.folder,
      'pdf' => MediaKind.pdf,
      _ => MediaKind.image,
    };
    return MediaItem(
      id: rawId,
      displayName: entry.displayName,
      kind: kind,
      folderRaw: entry.folderRaw,
      modified: entry.modifiedAt,
      sizeBytes: entry.sizeBytes,
      tags: const [],
    );
  }

  @override
  Future<FolderHandle?> pickFolder() async {
    throw const RemoteMediaException('クライアントモードではホスト側フォルダを直接選択できません');
  }

  @override
  Future<MediaItem?> pickSinglePdf() {
    return _localPickerRepository.pickSinglePdf();
  }

  @override
  Future<List<MediaItem>> pickExternalMediaFiles({
    bool allowMultiple = true,
    bool includeImages = true,
    bool includePdf = true,
  }) {
    return _localPickerRepository.pickExternalMediaFiles(
      allowMultiple: allowMultiple,
      includeImages: includeImages,
      includePdf: includePdf,
    );
  }

  @override
  Future<List<MediaItem>> resolveExternalItems(List<String> rawItems) {
    return _localPickerRepository.resolveExternalItems(rawItems);
  }

  @override
  Future<FolderHandle> getAppLibraryFolder() async {
    final folders = await listAvailableFolders();
    return folders.isNotEmpty
        ? folders.first
        : const FolderHandle('remote://library');
  }

  @override
  Future<List<MediaItem>> listMedia(
    FolderHandle folder, {
    void Function(int processed, int total)? onProgress,
  }) async {
    final items = <MediaItem>[];
    var offset = 0;
    const pageSize = 100;

    while (true) {
      final page = await _client.listFolderChildren(
        folder.raw,
        offset: offset,
        limit: pageSize,
      );
      items.addAll(page.items.map(_toMediaItem));
      onProgress?.call(items.length, page.total);
      if (items.length >= page.total || page.items.isEmpty) {
        break;
      }
      offset += page.items.length;
    }

    return items;
  }

  @override
  Future<int> importIntoFolder(
    FolderHandle folder, {
    void Function(MediaTransferProgress progress)? onProgress,
  }) async {
    final localItems = await pickExternalMediaFiles(
      allowMultiple: true,
      includeImages: true,
      includePdf: true,
    );
    if (localItems.isEmpty) {
      return 0;
    }
    return importItemsIntoFolder(
      folder,
      localItems,
      onProgress: onProgress,
    );
  }

  @override
  Future<ThumbPair> readThumbPair(MediaItem item, {int maxWidth = 360}) async {
    final mediaId = await _stableMediaId(item);
    final meta = await _metaForItem(item);
    final cacheDir = await _ensureCacheSubdir('thumbs');
    final cacheName = '${_cacheHash('$mediaId|${meta.etag}|$maxWidth')}.bin';
    final cacheFile = File(p.join(cacheDir.path, cacheName));

    final cached = await cacheFile.exists();
    if (cached) {
      return ThumbPair(front: await cacheFile.readAsBytes(), back: null);
    }

    final inFlight = _thumbInFlight[cacheFile.path];
    if (inFlight != null) {
      return inFlight;
    }

    final future = _client
        .fetchThumbnail(mediaId, width: maxWidth)
        .then((bytes) async {
          await cacheFile.parent.create(recursive: true);
          await cacheFile.writeAsBytes(bytes, flush: false);
          await _trimCacheDirectory(cacheDir, maxEntries: 320);
          _thumbInFlight.remove(cacheFile.path);
          return ThumbPair(front: bytes, back: null);
        })
        .catchError((Object error) {
          _thumbInFlight.remove(cacheFile.path);
          throw error;
        });

    _thumbInFlight[cacheFile.path] = future;
    return future;
  }

  @override
  Future<Uint8List> readBytes(MediaItem item) async {
    final file = await _ensureCachedMediaFile(item);
    return file.readAsBytes();
  }

  @override
  Future<int> getPageCount(MediaItem item) async {
    if (item.kind != MediaKind.pdf) {
      return 1;
    }
    final doc = await _openCachedPdf(item);
    return doc.pagesCount;
  }

  @override
  Future<Uint8List> renderPageBytes(
    MediaItem item,
    int page, {
    int maxWidth = 1600,
  }) async {
    if (item.kind != MediaKind.pdf) {
      return readBytes(item);
    }
    final doc = await _openCachedPdf(item);
    final total = doc.pagesCount;
    final current = page.clamp(1, total);
    return _renderPdfPage(doc, current, maxWidth);
  }

  @override
  Future<bool> deleteItem(MediaItem item) async {
    return item.kind != MediaKind.folder;
  }

  @override
  Future<int> deleteItems(List<MediaItem> items) async {
    return items.where((item) => item.kind != MediaKind.folder).length;
  }

  @override
  Future<MediaItem> rename(MediaItem item, String newDisplayName) async {
    final trimmed = newDisplayName.trim();
    if (trimmed.isEmpty) {
      throw const RemoteMediaException('新しい名前を入力してください');
    }

    final ext = _winPath.extension(item.displayName);
    final fixedName =
        ext.isNotEmpty && !trimmed.toLowerCase().endsWith(ext.toLowerCase())
        ? '$trimmed$ext'
        : trimmed;
    final nextPath = _winPath.join(item.folderRaw, fixedName);
    return MediaItem(
      id: nextPath,
      displayName: fixedName,
      kind: item.kind,
      folderRaw: item.folderRaw,
      modified: item.modified,
      sizeBytes: item.sizeBytes,
      tags: item.tags,
    );
  }

  @override
  Future<int> importItemsIntoFolder(
    FolderHandle dest,
    List<MediaItem> items, {
    bool skipIfExists = true,
    void Function(MediaTransferProgress progress)? onProgress,
  }) async {
    final uploadTargets =
        items.where((item) => item.kind != MediaKind.folder).toList(
          growable: false,
        );
    if (uploadTargets.isEmpty) {
      return 0;
    }

    final binaries = <RemoteUploadFile>[];
    for (final item in uploadTargets) {
      final bytes = await _localPickerRepository.readBytes(item);
      binaries.add(
        RemoteUploadFile(
          fileName: item.displayName,
          bytes: bytes,
          mimeType: item.kind == MediaKind.pdf
              ? 'application/pdf'
              : _mimeTypeForImage(item.displayName),
        ),
      );
    }

    final response = await _client.uploadFiles(
      folderRaw: dest.raw,
      files: binaries,
      skipIfExists: skipIfExists,
      onProgress: onProgress,
    );
    return response.importedCount;
  }

  String _mimeTypeForImage(String fileName) {
    final ext = _winPath.extension(fileName).toLowerCase();
    switch (ext) {
      case '.png':
        return 'image/png';
      case '.webp':
        return 'image/webp';
      case '.bmp':
        return 'image/bmp';
      default:
        return 'image/jpeg';
    }
  }

  @override
  Future<List<MediaItem>> listMediaRecursiveFiles(
    FolderHandle folder, {
    void Function(int processed, int total)? onProgress,
  }) async {
    final items = <MediaItem>[];
    var offset = 0;
    const pageSize = 200;

    while (true) {
      final page = await _client.searchMedia(
        folderRaw: folder.raw,
        offset: offset,
        limit: pageSize,
      );
      items.addAll(page.items.map(_toMediaItem));
      onProgress?.call(items.length, page.total);
      if (items.length >= page.total || page.items.isEmpty) {
        break;
      }
      offset += page.items.length;
    }

    return items
        .where((item) => item.kind != MediaKind.folder)
        .toList(growable: false);
  }

  @override
  Future<int> countMedia(FolderHandle folder) async {
    final page = await _client.listFolderChildren(folder.raw, offset: 0, limit: 1);
    return page.total;
  }

  @override
  Future<PagedMediaResult> listMediaPage(
    FolderHandle folder, {
    required int offset,
    required int limit,
    void Function(int processed, int total)? onProgress,
  }) async {
    final page = await _client.listFolderChildren(
      folder.raw,
      offset: offset,
      limit: limit,
    );
    onProgress?.call(page.items.length, page.total);
    return PagedMediaResult(
      items: page.items.map(_toMediaItem).toList(growable: false),
      total: page.total,
    );
  }

  Future<void> dispose() async {
    for (final doc in _pdfCache.values) {
      try {
        await doc.close();
      } catch (_) {}
    }
    _pdfCache.clear();
  }
}

class SwitchingMediaRepository implements MediaRepository {
  final MediaRepository _localRepository;
  final AppSettingsService _settingsService = AppSettingsService();

  MetadataSettings _settings;
  RemoteMediaRepository? _remoteRepository;

  SwitchingMediaRepository(
    this._localRepository, {
    required MetadataSettings initialSettings,
  }) : _settings = initialSettings {
    _remoteRepository = initialSettings.isClientMode
        ? RemoteMediaRepository.fromSettings(
            initialSettings,
            localPickerRepository: _localRepository,
          )
        : null;
  }

  @override
  AppMode get appMode => _settings.appMode;

  @override
  bool get isRemoteMode => _settings.appMode == AppMode.client;

  @override
  bool get isHostMode => _settings.appMode == AppMode.host;

  @override
  Future<void> reloadSettings() async {
    _settings = await _settingsService.loadMetadataSettings();
    if (_settings.isClientMode) {
      await _remoteRepository?.dispose();
      _remoteRepository = RemoteMediaRepository.fromSettings(
        _settings,
        localPickerRepository: _localRepository,
      );
    } else {
      await _remoteRepository?.dispose();
      _remoteRepository = null;
    }
  }

  @override
  Future<List<FolderHandle>> listAvailableFolders() async {
    if (!_settings.isClientMode) {
      return const <FolderHandle>[];
    }
    return _remoteRepository?.listAvailableFolders() ?? const <FolderHandle>[];
  }

  MediaRepository get _activeRepository {
    if (_settings.isClientMode) {
      final remote = _remoteRepository;
      if (remote == null) {
        throw const RemoteMediaException('クライアント設定の読み込みに失敗しました');
      }
      return remote;
    }
    return _localRepository;
  }

  @override
  Future<FolderHandle?> pickFolder() => _activeRepository.pickFolder();

  @override
  Future<MediaItem?> pickSinglePdf() => _activeRepository.pickSinglePdf();

  @override
  Future<List<MediaItem>> pickExternalMediaFiles({
    bool allowMultiple = true,
    bool includeImages = true,
    bool includePdf = true,
  }) {
    return _activeRepository.pickExternalMediaFiles(
      allowMultiple: allowMultiple,
      includeImages: includeImages,
      includePdf: includePdf,
    );
  }

  @override
  Future<List<MediaItem>> resolveExternalItems(List<String> rawItems) {
    return _activeRepository.resolveExternalItems(rawItems);
  }

  @override
  Future<FolderHandle> getAppLibraryFolder() => _activeRepository.getAppLibraryFolder();

  @override
  Future<List<MediaItem>> listMedia(
    FolderHandle folder, {
    void Function(int processed, int total)? onProgress,
  }) {
    return _activeRepository.listMedia(folder, onProgress: onProgress);
  }

  @override
  Future<int> importIntoFolder(
    FolderHandle folder, {
    void Function(MediaTransferProgress progress)? onProgress,
  }) => _activeRepository.importIntoFolder(folder, onProgress: onProgress);

  @override
  Future<ThumbPair> readThumbPair(MediaItem item, {int maxWidth = 360}) {
    return _activeRepository.readThumbPair(item, maxWidth: maxWidth);
  }

  @override
  Future<Uint8List> readBytes(MediaItem item) => _activeRepository.readBytes(item);

  @override
  Future<int> getPageCount(MediaItem item) => _activeRepository.getPageCount(item);

  @override
  Future<Uint8List> renderPageBytes(
    MediaItem item,
    int page, {
    int maxWidth = 1600,
  }) {
    return _activeRepository.renderPageBytes(item, page, maxWidth: maxWidth);
  }

  @override
  Future<bool> deleteItem(MediaItem item) => _activeRepository.deleteItem(item);

  @override
  Future<int> deleteItems(List<MediaItem> items) => _activeRepository.deleteItems(items);

  @override
  Future<MediaItem> rename(MediaItem item, String newDisplayName) {
    return _activeRepository.rename(item, newDisplayName);
  }

  @override
  Future<int> importItemsIntoFolder(
    FolderHandle dest,
    List<MediaItem> items, {
    bool skipIfExists = true,
    void Function(MediaTransferProgress progress)? onProgress,
  }) {
    return _activeRepository.importItemsIntoFolder(
      dest,
      items,
      skipIfExists: skipIfExists,
      onProgress: onProgress,
    );
  }

  @override
  Future<List<MediaItem>> listMediaRecursiveFiles(
    FolderHandle folder, {
    void Function(int processed, int total)? onProgress,
  }) {
    return _activeRepository.listMediaRecursiveFiles(folder, onProgress: onProgress);
  }

  @override
  Future<int> countMedia(FolderHandle folder) => _activeRepository.countMedia(folder);

  @override
  Future<PagedMediaResult> listMediaPage(
    FolderHandle folder, {
    required int offset,
    required int limit,
    void Function(int processed, int total)? onProgress,
  }) {
    return _activeRepository.listMediaPage(
      folder,
      offset: offset,
      limit: limit,
      onProgress: onProgress,
    );
  }
}
