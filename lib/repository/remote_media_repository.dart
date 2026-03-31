import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';

import '../media_file_types.dart';
import '../models/folder.dart';
import '../models/mediaItem.dart';
import '../models/metadata_settings.dart';
import '../models/tag.dart';
import '../services/app_settings_service.dart';
import '../services/import_source_normalizer.dart';
import '../services/media_id_resolver.dart';
import '../services/remote_media_api_client.dart';
import 'mediaRepository.dart';

enum _UploadSourceKind {
  contentUri,
  fileUri,
  path,
  unknown,
}

class _UploadReadResult {
  final Uint8List bytes;
  final String strategy;

  const _UploadReadResult({
    required this.bytes,
    required this.strategy,
  });
}

class RemoteMediaRepository implements MediaRepository {
  static final p.Context _winPath = p.Context(style: p.Style.windows);
  static final p.Context _posixPath = p.Context(style: p.Style.posix);
  static const Duration _sourceReadTimeout = Duration(minutes: 2);

  final RemoteMediaApiClient _client;
  final MediaRepository _localPickerRepository;
  final MediaIdResolver _idResolver;
  final LocalUploadTagsProvider? _localUploadTagsProvider;

  final Map<String, Future<ThumbPair>> _thumbInFlight =
      <String, Future<ThumbPair>>{};
  final Map<String, Future<File>> _downloadInFlight = <String, Future<File>>{};
  final Map<String, Future<Uint8List>> _previewInFlight =
      <String, Future<Uint8List>>{};
  final LinkedHashMap<String, PdfDocument> _pdfCache =
      LinkedHashMap<String, PdfDocument>();
  final Map<String, Future<RemoteMediaMeta>> _metaInFlight =
      <String, Future<RemoteMediaMeta>>{};
  final Map<String, RemoteMediaMeta> _metaCache = <String, RemoteMediaMeta>{};
  final Map<String, String> _remoteMediaIdsByPath = <String, String>{};

  Directory? _cacheRoot;

  RemoteMediaRepository({
    String baseUrl = '',
    String? authToken,
    required MediaRepository localPickerRepository,
    LocalUploadTagsProvider? localUploadTagsProvider,
    RemoteMediaApiClient? apiClient,
    MediaIdResolver? idResolver,
  }) : _localPickerRepository = localPickerRepository,
       _localUploadTagsProvider = localUploadTagsProvider,
       _client =
           apiClient ??
           RemoteMediaApiClient(
             baseUrl: baseUrl,
             authToken: authToken,
           ),
       _idResolver = idResolver ?? MediaIdResolver();

  factory RemoteMediaRepository.fromSettings(
    MetadataSettings settings, {
    required MediaRepository localPickerRepository,
    LocalUploadTagsProvider? localUploadTagsProvider,
  }) {
    return RemoteMediaRepository(
      baseUrl: settings.remoteApiBaseUrl,
      authToken: settings.authToken,
      localPickerRepository: localPickerRepository,
      localUploadTagsProvider: localUploadTagsProvider,
    );
  }

  @override
  AppMode get appMode => AppMode.client;

  @override
  RepositoryCapabilities get capabilities => const RepositoryCapabilities(
    canRename: true,
    canDelete: true,
    canUpload: true,
    canRecursiveSearch: true,
    canExportPdf: false,
    canOrganizeLibrary: false,
    canPickFolder: false,
    canAddLocalFolder: false,
    canImportToHost: true,
    canBatchUpload: true,
    canAssignImportTags: true,
  );

  @override
  bool get isRemoteMode => true;

  @override
  bool get isHostMode => false;

  @override
  bool get canImportFromUrl => true;

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
    final mediaId = await _remoteMediaIdForItem(item);
    final cached = _metaCache[mediaId];
    if (cached != null) {
      return cached;
    }
    final inFlight = _metaInFlight[mediaId];
    if (inFlight != null) {
      return inFlight;
    }
    final future = () async {
      try {
        try {
          final meta = await _client.fetchMediaMeta(mediaId);
          _metaCache[meta.mediaId] = meta;
          if (meta.mediaId != mediaId) {
            _metaCache[mediaId] = meta;
          }
          _rememberRemoteMediaId(item.id, meta.mediaId);
          return meta;
        } on RemoteMediaException catch (error) {
          if (error.statusCode != 404) {
            rethrow;
          }

          _evictMetaCache(mediaId);
          _forgetRemoteMediaId(item.id);
          final refreshedId = await _lookupRemoteMediaIdByPath(item);
          if (refreshedId == null ||
              refreshedId.isEmpty ||
              refreshedId == mediaId) {
            rethrow;
          }

          final meta = await _client.fetchMediaMeta(refreshedId);
          _metaCache[meta.mediaId] = meta;
          if (meta.mediaId != refreshedId) {
            _metaCache[refreshedId] = meta;
          }
          _rememberRemoteMediaId(item.id, meta.mediaId);
          return meta;
        }
      } finally {
        _metaInFlight.remove(mediaId);
      }
    }();
    _metaInFlight[mediaId] = future;
    return future;
  }

  Future<String> _stableMediaId(MediaItem item) async {
    final identity = await _idResolver.resolve(item);
    return identity.stableId;
  }

  bool _looksLikeRemoteMediaId(String raw) => raw.startsWith('mid_');

  String _normalizeRemotePath(String raw) {
    final normalizedRaw =
        ImportSourceNormalizer.normalizeSingleValue(raw)?.trim() ?? raw.trim();
    try {
      return _winPath.normalize(normalizedRaw).replaceAll('/', '\\').toLowerCase();
    } on ArgumentError {
      return normalizedRaw.replaceAll('/', '\\').toLowerCase();
    }
  }

  void _rememberRemoteMediaId(String fullPath, String mediaId) {
    final path = fullPath.trim();
    final id = mediaId.trim();
    if (path.isEmpty || id.isEmpty || _looksLikeRemoteMediaId(path)) {
      return;
    }
    _remoteMediaIdsByPath[_normalizeRemotePath(path)] = id;
  }

  void _forgetRemoteMediaId(String fullPath) {
    final path = fullPath.trim();
    if (path.isEmpty || _looksLikeRemoteMediaId(path)) {
      return;
    }
    _remoteMediaIdsByPath.remove(_normalizeRemotePath(path));
  }

  void _rememberRemoteEntry(RemoteFolderEntry entry) {
    final mediaId = entry.mediaId?.trim();
    final fullPath = (entry.fullPath ?? entry.entryId).trim();
    if (mediaId == null || mediaId.isEmpty || fullPath.isEmpty) {
      return;
    }
    _rememberRemoteMediaId(fullPath, mediaId);
  }

  Future<String?> _lookupRemoteMediaIdByPath(MediaItem item) async {
    if (item.kind == MediaKind.folder) {
      return null;
    }
    if (_looksLikeRemoteMediaId(item.id)) {
      return item.id;
    }

    final remembered = _remoteMediaIdsByPath[_normalizeRemotePath(item.id)];
    if (remembered != null && remembered.isNotEmpty) {
      return remembered;
    }

    final entry = await _findFolderChildByPath(item.folderRaw, item.id);
    if (entry == null) {
      return null;
    }
    _rememberRemoteEntry(entry);
    final mediaId = entry.mediaId?.trim();
    if (mediaId == null || mediaId.isEmpty) {
      return null;
    }
    return mediaId;
  }

  Future<String> _remoteMediaIdForItem(MediaItem item) async {
    final remembered = await _lookupRemoteMediaIdByPath(item);
    if (remembered != null && remembered.isNotEmpty) {
      return remembered;
    }
    return _stableMediaId(item);
  }

  void _evictMetaCache(String stableId) {
    _metaCache.remove(stableId);
    _metaInFlight.remove(stableId);
  }

  Future<RemoteFolderEntry?> _findFolderChildByPath(
    String folderRaw,
    String fullPath,
  ) async {
    var offset = 0;
    const pageSize = 200;

    while (true) {
      final page = await _client.listFolderChildren(
        folderRaw,
        offset: offset,
        limit: pageSize,
      );
      for (final entry in page.items) {
        final entryPath = entry.fullPath ?? entry.entryId;
        if (_winPath.equals(entryPath, fullPath)) {
          return entry;
        }
      }

      if (page.items.isEmpty || (offset + page.items.length) >= page.total) {
        return null;
      }
      offset += page.items.length;
    }
  }

  MediaKind _mediaKindFromRemote(String rawKind) {
    switch (rawKind) {
      case 'pdf':
        return MediaKind.pdf;
      case 'image':
        return MediaKind.image;
      default:
        throw RemoteMediaException('未対応のメディア種別です: $rawKind');
    }
  }

  Future<void> _assertDeleted(
    MediaItem item,
    String stableId,
  ) async {
    try {
      await _client.fetchMediaMeta(stableId);
    } on RemoteMediaException catch (error) {
      if (error.statusCode == 404) {
        return;
      }
      rethrow;
    }

    throw RemoteMediaException('削除確認に失敗しました: ${item.displayName}');
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
    if (meta.mimeType == 'image/avif') {
      return '.avif';
    }
    if (meta.mimeType == 'image/webp') {
      return '.webp';
    }
    if (meta.mimeType == 'image/bmp' || meta.mimeType == 'image/x-ms-bmp') {
      return '.bmp';
    }
    return '.jpg';
  }

  Future<File> _ensureCachedMediaFile(MediaItem item) async {
    final meta = await _metaForItem(item);
    final mediaId = meta.mediaId;
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
    _rememberRemoteEntry(entry);
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
    throw const RemoteMediaException(
      'クライアントモードではホスト側フォルダを直接選択できません',
    );
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
    ImportRequest? request,
    void Function(MediaTransferProgress progress)? onProgress,
  }) async {
    final resolvedRequest = request ?? const ImportRequest();
    onProgress?.call(
      MediaTransferProgress(
        sentBytes: 0,
        totalBytes: 0,
        completedFiles: 0,
        totalFiles: 0,
        statusLabel: resolvedRequest.sourceKind == ImportSourceKind.folder
            ? '取り込み元フォルダを選択しています'
            : '取り込み元ファイルを選択しています',
      ),
    );
    final localItems = await switch (resolvedRequest.sourceKind) {
      ImportSourceKind.folder => () async {
        final sourceFolder = await _localPickerRepository.pickFolder();
        if (sourceFolder == null) {
          return const <MediaItem>[];
        }
        return _localPickerRepository.listMediaRecursiveFiles(
          sourceFolder,
          onProgress: (processed, total) {
            onProgress?.call(
              MediaTransferProgress(
                sentBytes: 0,
                totalBytes: 0,
                completedFiles: processed,
                totalFiles: total,
                statusLabel: '取り込み元フォルダを走査しています',
              ),
            );
          },
        );
      }(),
      ImportSourceKind.files => pickExternalMediaFiles(
        allowMultiple: true,
        includeImages: true,
        includePdf: true,
      ),
    };
    if (localItems.isEmpty) {
      return 0;
    }
    return importItemsIntoFolder(
      folder,
      localItems,
      importMetadata: resolvedRequest.metadata,
      skipIfExists: resolvedRequest.skipIfExists,
      onProgress: onProgress,
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
      throw const RemoteMediaException(
        'URL、URL一覧ファイル、またはお気に入り取得のいずれかを指定してください',
      );
    }

    return _client.downloadUrl(
      folderRaw: folder.raw,
      sourceUrl: trimmedUrl,
      importMetadata: importMetadata,
      options: effectiveOptions,
    );
  }


  @override
  Future<ThumbPair> readThumbPair(MediaItem item, {int maxWidth = 360}) async {
    final meta = await _metaForItem(item);
    final mediaId = meta.mediaId;
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

  Future<Uint8List> _readDisplayImageBytes(
    MediaItem item, {
    required int maxWidth,
  }) async {
    final meta = await _metaForItem(item);
    final mediaId = meta.mediaId;
    final cacheDir = await _ensureCacheSubdir('previews');
    final targetWidth = maxWidth.clamp(320, 2048).toInt();
    final targetHeight = (targetWidth * 2).clamp(640, 4096).toInt();
    final cacheName =
        '${_cacheHash('$mediaId|${meta.etag}|preview|$targetWidth|$targetHeight')}.jpg';
    final cacheFile = File(p.join(cacheDir.path, cacheName));

    if (await cacheFile.exists()) {
      return cacheFile.readAsBytes();
    }

    final inFlight = _previewInFlight[cacheFile.path];
    if (inFlight != null) {
      return inFlight;
    }

    final future = _client
        .fetchThumbnail(
          mediaId,
          width: targetWidth,
          height: targetHeight,
        )
        .then((bytes) async {
          await cacheFile.parent.create(recursive: true);
          await cacheFile.writeAsBytes(bytes, flush: false);
          await _trimCacheDirectory(cacheDir, maxEntries: 96);
          _previewInFlight.remove(cacheFile.path);
          return bytes;
        })
        .catchError((Object error) {
          _previewInFlight.remove(cacheFile.path);
          throw error;
        });

    _previewInFlight[cacheFile.path] = future;
    return future;
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
      return _readDisplayImageBytes(item, maxWidth: maxWidth);
    }
    final doc = await _openCachedPdf(item);
    final total = doc.pagesCount;
    final current = page.clamp(1, total);
    return _renderPdfPage(doc, current, maxWidth);
  }

  @override
  Future<bool> deleteItem(MediaItem item) async {
    final deletedCount = await deleteItems(<MediaItem>[item]);
    return deletedCount == 1;
  }

  @override
  Future<int> deleteItems(List<MediaItem> items) async {
    final targets = items
        .where((item) => item.kind != MediaKind.folder)
        .toList(growable: false);
    if (targets.isEmpty) {
      return 0;
    }

    final payload = <(MediaItem, ResolvedMediaIdentity, String)>[];
    for (final item in targets) {
      payload.add((
        item,
        await _idResolver.resolve(item),
        await _remoteMediaIdForItem(item),
      ));
    }

    await _client.deleteMedia(
      payload.map((entry) => (entry.$1, entry.$2)).toList(growable: false),
      hardDelete: true,
    );
    for (final entry in payload) {
      await _assertDeleted(entry.$1, entry.$3);
      _evictMetaCache(entry.$3);
      _forgetRemoteMediaId(entry.$1.id);
      _idResolver.forget(entry.$1);
    }
    return payload.length;
  }

  @override
  Future<MediaItem> rename(MediaItem item, String newDisplayName) async {
    if (item.kind == MediaKind.folder) {
      throw const RemoteMediaException('フォルダ名の変更は未対応です');
    }
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
    final nextItem = MediaItem(
      id: nextPath,
      displayName: fixedName,
      kind: item.kind,
      folderRaw: item.folderRaw,
      modified: item.modified,
      sizeBytes: item.sizeBytes,
      tags: item.tags,
    );

    final beforeRemoteMediaId = await _remoteMediaIdForItem(item);
    final beforeIdentity = await _idResolver.resolve(item);
    final afterIdentity = await _idResolver.resolve(nextItem);
    await _client.renameMedia(
      beforeItem: item,
      afterItem: nextItem,
      beforeIdentity: beforeIdentity,
      afterIdentity: afterIdentity,
    );

    final refreshed = await _findFolderChildByPath(nextItem.folderRaw, nextPath);
    if (refreshed == null) {
      throw const RemoteMediaException('リネーム後のメディア取得に失敗しました');
    }

    _evictMetaCache(beforeRemoteMediaId);
    if (refreshed.mediaId != null && refreshed.mediaId!.isNotEmpty) {
      _evictMetaCache(refreshed.mediaId!);
    }
    _forgetRemoteMediaId(item.id);
    _forgetRemoteMediaId(nextItem.id);
    _rememberRemoteEntry(refreshed);
    _idResolver.forget(item);
    _idResolver.forget(nextItem);

    return MediaItem(
      id: refreshed.fullPath ?? nextItem.id,
      displayName: refreshed.displayName,
      kind: _mediaKindFromRemote(refreshed.kind),
      folderRaw: refreshed.folderRaw,
      modified: refreshed.modifiedAt ?? nextItem.modified,
      sizeBytes: refreshed.sizeBytes ?? nextItem.sizeBytes,
      tags: item.tags,
    );
  }

  @override
  Future<int> importItemsIntoFolder(
    FolderHandle dest,
    List<MediaItem> items, {
    ImportMetadata? importMetadata,
    bool skipIfExists = true,
    void Function(MediaTransferProgress progress)? onProgress,
  }) async {
    try {
      final uploadTargets =
          items.where((item) => item.kind != MediaKind.folder).toList(
            growable: false,
          );
      if (uploadTargets.isEmpty) {
        return 0;
      }

      final unsupported = uploadTargets
          .map(
            (item) => _sanitizeUploadFileName(item.displayName) ?? item.displayName,
          )
          .where((name) => !MediaFileTypes.isSupportedMediaFileName(name))
          .toList(growable: false);
      if (unsupported.isNotEmpty) {
        throw RemoteMediaException('未対応のファイル形式です: ${unsupported.join(', ')}');
      }

      final binaries = <RemoteUploadFile>[];
      final readFailures = <String>[];
      final localStoredTagsByItemId = await _loadLocalUploadTags(uploadTargets);
      onProgress?.call(
        MediaTransferProgress(
          sentBytes: 0,
          totalBytes: 0,
          completedFiles: 0,
          totalFiles: uploadTargets.length,
          statusLabel: '取り込み対象を確認しています',
        ),
      );

      for (final rawItem in uploadTargets) {
        final item = await _normalizeUploadSourceItem(rawItem);
        final fileName = _normalizedUploadFileName(item);
        final sourceKindLabel = _sourceKindLabelForItem(item, rawId: rawItem.id);
        final sourceKind = _sourceKindNameForItem(item, rawId: rawItem.id);
        debugPrint(
          '[remote-upload] source '
          'sourceKind=${sourceKind} '
          'rawId=${rawItem.id} normalizedId=${item.id} '
          'display=${item.displayName} folder=${item.folderRaw}',
        );
        onProgress?.call(
          MediaTransferProgress(
            sentBytes: 0,
            totalBytes: 0,
            completedFiles: binaries.length,
            totalFiles: uploadTargets.length,
            currentFileName: fileName,
            statusLabel: '$sourceKindLabel を読み込み中',
          ),
        );

        late final _UploadReadResult readResult;
        try {
          readResult = await _readUploadSourceBytes(
            originalItem: rawItem,
            normalizedItem: item,
            fileName: fileName,
            sourceKindLabel: sourceKindLabel,
          );
        } catch (error, stackTrace) {
          debugPrint(
            '[remote-upload] read failed '
            'name=$fileName sourceKind=$sourceKindLabel '
            'rawId=${rawItem.id} normalizedId=${item.id} '
            'folder=${item.folderRaw} error=$error',
          );
          debugPrintStack(
            label: '[remote-upload] read failed stack',
            stackTrace: stackTrace,
          );
          readFailures.add('$fileName ($sourceKindLabel): $error');
          continue;
        }

        final sourceRelativePath = _sourceRelativePathForUpload(
          item,
          fallbackFileName: fileName,
        );
        final itemTags = _mergeUploadTags(
          rawItem.tags,
          item.tags,
          localStoredTagsByItemId[rawItem.id] ?? const <Tag>[],
        );
        debugPrint(
          '[remote-upload] prepared '
          'name=$fileName sourceKind=$sourceKindLabel '
          'strategy=${readResult.strategy} '
          'relative=${sourceRelativePath ?? '-'} bytes=${readResult.bytes.length} '
          'tags=${itemTags.length}',
        );
        binaries.add(
          RemoteUploadFile(
            fileName: fileName,
            bytes: readResult.bytes,
            mimeType: item.kind == MediaKind.pdf
                ? 'application/pdf'
                : _mimeTypeForImage(fileName),
            sourceRelativePath: sourceRelativePath,
            tags: itemTags,
          ),
        );
      }

      if (readFailures.isNotEmpty) {
        debugPrint(
          '[remote-upload] aborted before upload due to read failures '
          'count=${readFailures.length}',
        );
        final summary = readFailures.map((entry) => '- $entry').join('\n');
        throw RemoteMediaException(
          '取り込み元ファイルの読み込みに失敗したため、アップロードを中止しました。\n'
          '$summary',
        );
      }

      final uploadTotalBytes = binaries.fold<int>(
        0,
        (sum, file) => sum + file.bytes.length,
      );
      onProgress?.call(
        MediaTransferProgress(
          sentBytes: 0,
          totalBytes: uploadTotalBytes,
          completedFiles: 0,
          totalFiles: binaries.length,
          statusLabel: 'ホストへアップロードしています',
        ),
      );

      debugPrint(
        '[remote-upload] dispatch '
        'count=${binaries.length} names=${binaries.map((file) => file.fileName).join(' | ')}',
      );
      late final RemoteUploadResponse response;
      try {
        response = await _client.uploadFiles(
          folderRaw: dest.raw,
          files: binaries,
          importMetadata: importMetadata,
          skipIfExists: skipIfExists,
          onProgress: onProgress,
        );
      } catch (error, stackTrace) {
        debugPrint(
          '[remote-upload] upload request failed '
          'count=${binaries.length} folder=${dest.raw} error=$error',
        );
        debugPrintStack(
          label: '[remote-upload] upload request failed stack',
          stackTrace: stackTrace,
        );
        rethrow;
      }
      onProgress?.call(
        MediaTransferProgress(
          sentBytes: uploadTotalBytes,
          totalBytes: uploadTotalBytes,
          completedFiles: binaries.length,
          totalFiles: binaries.length,
          statusLabel: 'ホスト側の取り込みが完了しました',
        ),
      );
      debugPrint(
        '[remote-upload] response '
        'imported=${response.importedCount} skipped=${response.skippedCount} '
        'tagged=${response.taggedCount} organized=${response.organizedCount} '
        'rescanned=${response.rescannedCount}',
      );
      return response.importedCount;
    } on ArgumentError catch (error, stackTrace) {
      debugPrint(
        '[remote-upload] invalid path argument during host import: '
        '$error dest=${dest.raw}\n$stackTrace',
      );
      throw RemoteMediaException(
        '取り込み元パスの解釈に失敗しました。'
        'ファイル名またはパスに不正な文字列が混ざっている可能性があります。\n$error',
      );
    }
  }

  Future<Map<String, List<Tag>>> _loadLocalUploadTags(
    List<MediaItem> items,
  ) async {
    final provider = _localUploadTagsProvider;
    if (provider == null || items.isEmpty) {
      return const <String, List<Tag>>{};
    }

    try {
      return await provider(items);
    } catch (error, stackTrace) {
      debugPrint('[remote-upload] local tag lookup failed: $error');
      debugPrintStack(
        label: '[remote-upload] local tag lookup stack',
        stackTrace: stackTrace,
      );
      return const <String, List<Tag>>{};
    }
  }

  List<Tag> _mergeUploadTags(Iterable<Tag> first, Iterable<Tag> second, Iterable<Tag> third) {
    final merged = <Tag>[];
    final seen = <String>{};

    void appendAll(Iterable<Tag> tags) {
      for (final tag in tags) {
        final normalizedName = tag.name.trim();
        if (normalizedName.isEmpty) {
          continue;
        }
        final key = '${tag.category.name}\u0000${normalizedName.toLowerCase()}';
        if (!seen.add(key)) {
          continue;
        }
        merged.add(Tag(name: normalizedName, category: tag.category));
      }
    }

    appendAll(first);
    appendAll(second);
    appendAll(third);
    return merged;
  }

  String _mimeTypeForImage(String fileName) {
    return MediaFileTypes.imageMimeTypeForFileName(fileName);
  }

  String _normalizedUploadFileName(MediaItem item) {
    final displayName = _sanitizeUploadFileName(item.displayName);
    if (displayName != null) {
      return displayName;
    }

    final fromPath = _sanitizeUploadFileName(
      ImportSourceNormalizer.basenameFromPathish(item.id),
    );
    if (fromPath != null) {
      return fromPath;
    }

    throw RemoteMediaException('アップロード元のファイル名を特定できません: ${item.id}');
  }

  Future<MediaItem> _normalizeUploadSourceItem(MediaItem item) async {
    try {
      final normalizedDisplayName = _normalizedUploadFileName(item);
      final normalizedId = _normalizedUploadId(item.id);
      final normalizedFolderRaw = _normalizedUploadFolderRaw(
        item.folderRaw,
        fallbackId: normalizedId,
      );

      return MediaItem(
        id: normalizedId,
        displayName: normalizedDisplayName,
        kind: item.kind,
        folderRaw: normalizedFolderRaw,
        modified: item.modified,
        sizeBytes: item.sizeBytes,
        tags: item.tags,
      );
    } catch (error, stackTrace) {
      final fallbackDisplayName = _sanitizeUploadFileName(item.displayName) ??
          _sanitizeUploadFileName(
            ImportSourceNormalizer.basenameFromPathish(item.id),
          ) ??
          'upload.bin';
      debugPrint(
        '[remote-upload] source normalization fallback: '
        '$error rawId=${item.id} folder=${item.folderRaw}',
      );
      debugPrintStack(
        label: '[remote-upload] source normalization stack',
        stackTrace: stackTrace,
      );
      return MediaItem(
        id: _normalizedUploadId(item.id),
        displayName: fallbackDisplayName,
        kind: item.kind,
        folderRaw: _normalizedUploadFolderRaw(
          item.folderRaw,
          fallbackId: item.id,
        ),
        modified: item.modified,
        sizeBytes: item.sizeBytes,
        tags: item.tags,
      );
    }
  }

  String _normalizedUploadId(String rawId) {
    final trimmed = rawId.trim();
    if (trimmed.isEmpty || trimmed.startsWith('content://')) {
      return trimmed;
    }
    final normalized =
        ImportSourceNormalizer.normalizeSingleValue(trimmed)?.trim() ?? trimmed;
    return normalized.isEmpty ? trimmed : normalized;
  }

  String _normalizedUploadFolderRaw(
    String rawFolderRaw, {
    required String fallbackId,
  }) {
    final trimmed = rawFolderRaw.trim();
    if (trimmed.isEmpty) {
      return fallbackId.startsWith('content://') ? fallbackId : '';
    }
    if (trimmed.startsWith('content://')) {
      return trimmed;
    }
    final normalized =
        ImportSourceNormalizer.normalizeSingleValue(trimmed)?.trim() ?? trimmed;
    return normalized;
  }

  String? _sanitizeUploadFileName(String raw) {
    var value = raw.trim();
    if (value.isEmpty) {
      return null;
    }

    if (ImportSourceNormalizer.looksLikeEncodedCollection(value) ||
        value.contains('/') ||
        value.contains('\\')) {
      value = ImportSourceNormalizer.basenameFromPathish(value);
    }

    value = value
        .replaceAll(RegExp(r'[<>:\"/\\|?*\x00-\x1F]+'), '_')
        .replaceAll(RegExp(r'[\r\n]+'), ' ')
        .trim();
    while (value.endsWith('.') || value.endsWith(' ')) {
      value = value.substring(0, value.length - 1).trimRight();
    }
    if (value.isEmpty || value == '.' || value == '..') {
      return null;
    }
    return value;
  }

  Future<_UploadReadResult> _readUploadSourceBytes({
    required MediaItem originalItem,
    required MediaItem normalizedItem,
    required String fileName,
    required String sourceKindLabel,
  }) async {
    final rawId = originalItem.id.trim();
    final normalizedId = normalizedItem.id.trim();
    final sourceKind = _classifyUploadSource(
      rawId: rawId,
      normalizedId: normalizedId,
    );

    if (sourceKind == _UploadSourceKind.contentUri) {
      return _readBytesViaLocalPicker(
        originalItem: originalItem,
        normalizedItem: normalizedItem,
        fileName: fileName,
        sourceKindLabel: sourceKindLabel,
        strategy: 'content-uri',
      );
    }

    final fileUriPath = _filePathFromFileUri(rawId) ??
        _filePathFromFileUri(normalizedId);
    if (fileUriPath != null) {
      return _readBytesViaFilePath(
        originalItem: originalItem,
        normalizedItem: normalizedItem,
        fileName: fileName,
        sourceKindLabel: sourceKindLabel,
        strategy: 'file-uri',
        candidatePath: fileUriPath,
      );
    }

    final directPath =
        _normalizeLocalPathCandidate(normalizedId) ??
        _normalizeLocalPathCandidate(rawId);
    if (directPath != null) {
      try {
        return await _readBytesViaFilePath(
          originalItem: originalItem,
          normalizedItem: normalizedItem,
          fileName: fileName,
          sourceKindLabel: sourceKindLabel,
          strategy: 'path',
          candidatePath: directPath,
        );
      } catch (error, stackTrace) {
        debugPrint(
          '[remote-upload] direct path read failed, trying fallback '
          'rawId=${originalItem.id} normalizedId=${normalizedItem.id} '
          'candidate=$directPath error=$error',
        );
        debugPrintStack(
          label: '[remote-upload] direct path read failed stack',
          stackTrace: stackTrace,
        );
      }
    }

    final fallbackPath = await _lastResortUploadPath(
      originalItem: originalItem,
      normalizedItem: normalizedItem,
      fileName: fileName,
    );
    if (fallbackPath != null) {
      return _readBytesViaFilePath(
        originalItem: originalItem,
        normalizedItem: normalizedItem,
        fileName: fileName,
        sourceKindLabel: sourceKindLabel,
        strategy: 'fallback-path',
        candidatePath: fallbackPath,
      );
    }

    throw RemoteMediaException(
      '取り込み元ファイルを特定できませんでした: $fileName '
      '(sourceKind=${_sourceKindNameForItem(normalizedItem, rawId: originalItem.id)})',
    );
  }

  Future<_UploadReadResult> _readBytesViaLocalPicker({
    required MediaItem originalItem,
    required MediaItem normalizedItem,
    required String fileName,
    required String sourceKindLabel,
    required String strategy,
  }) async {
    _logUploadReadStart(
      strategy: strategy,
      originalItem: originalItem,
      normalizedItem: normalizedItem,
      fileName: fileName,
    );
    final watch = Stopwatch()..start();
    try {
      final bytes = await _localPickerRepository.readBytes(normalizedItem).timeout(
        _sourceReadTimeout,
        onTimeout: () => throw RemoteMediaException(
          '$sourceKindLabel の読み込みがタイムアウトしました: $fileName',
        ),
      );
      watch.stop();
      _logUploadReadSuccess(
        strategy: strategy,
        originalItem: originalItem,
        normalizedItem: normalizedItem,
        fileName: fileName,
        bytesLength: bytes.length,
        elapsed: watch.elapsed,
      );
      return _UploadReadResult(bytes: bytes, strategy: strategy);
    } catch (error, stackTrace) {
      watch.stop();
      _logUploadReadFailure(
        strategy: strategy,
        originalItem: originalItem,
        normalizedItem: normalizedItem,
        fileName: fileName,
        error: error,
        stackTrace: stackTrace,
        elapsed: watch.elapsed,
      );
      rethrow;
    }
  }

  Future<_UploadReadResult> _readBytesViaFilePath({
    required MediaItem originalItem,
    required MediaItem normalizedItem,
    required String fileName,
    required String sourceKindLabel,
    required String strategy,
    required String candidatePath,
  }) async {
    _logUploadReadStart(
      strategy: strategy,
      originalItem: originalItem,
      normalizedItem: normalizedItem,
      fileName: fileName,
      candidatePath: candidatePath,
    );
    final watch = Stopwatch()..start();
    try {
      final file = File(candidatePath);
      final exists = await file.exists().timeout(
        _sourceReadTimeout,
        onTimeout: () => throw RemoteMediaException(
          '$sourceKindLabel の存在確認がタイムアウトしました: $fileName',
        ),
      );
      if (!exists) {
        throw RemoteMediaException('ファイルが見つかりません: $candidatePath');
      }
      final bytes = await file.readAsBytes().timeout(
        _sourceReadTimeout,
        onTimeout: () => throw RemoteMediaException(
          '$sourceKindLabel の読み込みがタイムアウトしました: $fileName',
        ),
      );
      watch.stop();
      _logUploadReadSuccess(
        strategy: strategy,
        originalItem: originalItem,
        normalizedItem: normalizedItem,
        fileName: fileName,
        bytesLength: bytes.length,
        elapsed: watch.elapsed,
        candidatePath: candidatePath,
      );
      return _UploadReadResult(bytes: bytes, strategy: strategy);
    } catch (error, stackTrace) {
      watch.stop();
      _logUploadReadFailure(
        strategy: strategy,
        originalItem: originalItem,
        normalizedItem: normalizedItem,
        fileName: fileName,
        error: error,
        stackTrace: stackTrace,
        elapsed: watch.elapsed,
        candidatePath: candidatePath,
      );
      rethrow;
    }
  }

  Future<String?> _lastResortUploadPath({
    required MediaItem originalItem,
    required MediaItem normalizedItem,
    required String fileName,
  }) async {
    final folderCandidates = <String>{
      normalizedItem.folderRaw,
      originalItem.folderRaw,
    }
        .map(_normalizeLocalPathCandidate)
        .whereType<String>()
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    final nameCandidates = <String>{
      fileName,
      normalizedItem.displayName,
      ImportSourceNormalizer.basenameFromPathish(originalItem.id),
      ImportSourceNormalizer.basenameFromPathish(normalizedItem.id),
    }
        .map(_sanitizeUploadFileName)
        .whereType<String>()
        .where((value) => value.isNotEmpty)
        .toList(growable: false);

    for (final folderPath in folderCandidates) {
      final ctx = _pathContextFor(folderPath.contains('\\'));
      for (final name in nameCandidates) {
        try {
          final candidate = _normalizeLocalPathCandidate(ctx.join(folderPath, name));
          if (candidate == null) {
            continue;
          }
          if (await File(candidate).exists()) {
            return candidate;
          }
        } catch (_) {}
      }
    }
    return null;
  }

  _UploadSourceKind _classifyUploadSource({
    required String rawId,
    required String normalizedId,
  }) {
    final raw = rawId.trim().toLowerCase();
    final normalized = normalizedId.trim().toLowerCase();
    if (raw.contains('content://') || normalized.startsWith('content://')) {
      return _UploadSourceKind.contentUri;
    }
    if (raw.contains('file://') || normalized.startsWith('file://')) {
      return _UploadSourceKind.fileUri;
    }
    if (normalized.isEmpty) {
      return _UploadSourceKind.unknown;
    }
    if (_normalizeLocalPathCandidate(normalizedId) != null) {
      return _UploadSourceKind.path;
    }
    return _UploadSourceKind.unknown;
  }

  String _sourceKindNameForItem(MediaItem item, {String? rawId}) {
    final kind = _classifyUploadSource(
      rawId: rawId ?? item.id,
      normalizedId: item.id,
    );
    return switch (kind) {
      _UploadSourceKind.contentUri => 'content',
      _UploadSourceKind.fileUri => 'file',
      _UploadSourceKind.path => 'path',
      _UploadSourceKind.unknown => 'unknown',
    };
  }

  String? _filePathFromFileUri(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    if (!trimmed.startsWith('file://')) {
      return null;
    }
    try {
      return Uri.parse(trimmed).toFilePath();
    } catch (_) {
      return null;
    }
  }

  String? _normalizeLocalPathCandidate(String raw) {
    final normalized =
        ImportSourceNormalizer.normalizeSingleValue(raw)?.trim() ?? raw.trim();
    if (normalized.isEmpty || normalized.startsWith('content://')) {
      return null;
    }
    if (normalized.startsWith('file://')) {
      return _filePathFromFileUri(normalized);
    }
    final ctx = _pathContextFor(normalized.contains('\\'));
    try {
      return ctx.normalize(normalized);
    } on ArgumentError {
      return null;
    }
  }

  String _sourceKindLabelForItem(MediaItem item, {String? rawId}) {
    final kind = _classifyUploadSource(
      rawId: rawId ?? item.id,
      normalizedId: item.id,
    );
    return switch (kind) {
      _UploadSourceKind.contentUri => 'Android URI',
      _UploadSourceKind.fileUri => 'file URI',
      _UploadSourceKind.path => 'ファイルパス',
      _UploadSourceKind.unknown => '不明な入力',
    };
  }

  void _logUploadReadStart({
    required String strategy,
    required MediaItem originalItem,
    required MediaItem normalizedItem,
    required String fileName,
    String? candidatePath,
  }) {
    debugPrint(
      '[remote-upload] read start '
      'strategy=$strategy '
      'rawId=${originalItem.id} normalizedId=${normalizedItem.id} '
      'sourceKind=${_sourceKindNameForItem(normalizedItem, rawId: originalItem.id)} '
      'display=${normalizedItem.displayName} folder=${normalizedItem.folderRaw} '
      'fileName=$fileName candidate=${candidatePath ?? '-'}',
    );
  }

  void _logUploadReadSuccess({
    required String strategy,
    required MediaItem originalItem,
    required MediaItem normalizedItem,
    required String fileName,
    required int bytesLength,
    required Duration elapsed,
    String? candidatePath,
  }) {
    debugPrint(
      '[remote-upload] read success '
      'strategy=$strategy bytes=$bytesLength elapsedMs=${elapsed.inMilliseconds} '
      'rawId=${originalItem.id} normalizedId=${normalizedItem.id} '
      'display=${normalizedItem.displayName} folder=${normalizedItem.folderRaw} '
      'fileName=$fileName candidate=${candidatePath ?? '-'}',
    );
  }

  void _logUploadReadFailure({
    required String strategy,
    required MediaItem originalItem,
    required MediaItem normalizedItem,
    required String fileName,
    required Object error,
    required StackTrace stackTrace,
    required Duration elapsed,
    String? candidatePath,
  }) {
    debugPrint(
      '[remote-upload] read failure '
      'strategy=$strategy timeout=${error is TimeoutException} '
      'elapsedMs=${elapsed.inMilliseconds} '
      'rawId=${originalItem.id} normalizedId=${normalizedItem.id} '
      'sourceKind=${_sourceKindNameForItem(normalizedItem, rawId: originalItem.id)} '
      'display=${normalizedItem.displayName} folder=${normalizedItem.folderRaw} '
      'fileName=$fileName candidate=${candidatePath ?? '-'} error=$error',
    );
    debugPrintStack(
      label: '[remote-upload] read failure stack',
      stackTrace: stackTrace,
    );
  }

  String? _sourceRelativePathForUpload(
    MediaItem item, {
    required String fallbackFileName,
  }) {
    try {
      final rawPath =
          ImportSourceNormalizer.normalizeSingleValue(item.id) ?? item.id.trim();
      final rawRoot =
          ImportSourceNormalizer.normalizeSingleValue(item.folderRaw) ??
          item.folderRaw.trim();
      if (rawPath.isEmpty || rawRoot.isEmpty) {
        return null;
      }
      if (rawPath.startsWith('content://') || rawRoot.startsWith('content://')) {
        return null;
      }

      final ctx = _pathContextFor(rawPath.contains('\\') || rawRoot.contains('\\'));
      final normalizedPath = ctx.normalize(rawPath);
      final normalizedRoot = ctx.normalize(rawRoot);
      if (!ctx.isWithin(normalizedRoot, normalizedPath)) {
        return fallbackFileName;
      }

      final relative = ctx.relative(normalizedPath, from: normalizedRoot).trim();
      if (relative.isEmpty || relative == '.') {
        return fallbackFileName;
      }
      return relative.replaceAll('\\', '/');
    } on ArgumentError catch (error) {
      debugPrint(
        '[remote-upload] skipped relative path normalization: $error '
        'item=${item.id} folder=${item.folderRaw}',
      );
      return fallbackFileName;
    } catch (error, stackTrace) {
      debugPrint(
        '[remote-upload] relative path fallback failed: '
        '$error item=${item.id} folder=${item.folderRaw}\n$stackTrace',
      );
      return fallbackFileName;
    }
  }

  p.Context _pathContextFor(bool looksWindowsPath) {
    return looksWindowsPath ? _winPath : _posixPath;
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
  final LocalUploadTagsProvider? _localUploadTagsProvider;
  final AppSettingsService _settingsService = AppSettingsService();

  MetadataSettings _settings;
  RemoteMediaRepository? _remoteRepository;

  SwitchingMediaRepository(
    this._localRepository, {
    required MetadataSettings initialSettings,
    LocalUploadTagsProvider? localUploadTagsProvider,
  }) : _settings = initialSettings,
       _localUploadTagsProvider = localUploadTagsProvider {
    _remoteRepository = initialSettings.isClientMode
        ? RemoteMediaRepository.fromSettings(
            initialSettings,
            localPickerRepository: _localRepository,
            localUploadTagsProvider: _localUploadTagsProvider,
          )
        : null;
  }

  @override
  AppMode get appMode => _settings.appMode;

  @override
  RepositoryCapabilities get capabilities => _activeRepository.capabilities;

  @override
  bool get isRemoteMode => _settings.appMode == AppMode.client;

  @override
  bool get isHostMode => _settings.appMode == AppMode.host;

  @override
  bool get canImportFromUrl => _activeRepository.canImportFromUrl;

  @override
  Future<void> reloadSettings() async {
    _settings = await _settingsService.loadMetadataSettings();
    if (_settings.isClientMode) {
      await _remoteRepository?.dispose();
      _remoteRepository = RemoteMediaRepository.fromSettings(
        _settings,
        localPickerRepository: _localRepository,
        localUploadTagsProvider: _localUploadTagsProvider,
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
    ImportRequest? request,
    void Function(MediaTransferProgress progress)? onProgress,
  }) => _activeRepository.importIntoFolder(
    folder,
    request: request,
    onProgress: onProgress,
  );


  @override
  Future<UrlImportResult> importFromUrlIntoFolder(
    FolderHandle folder,
    String sourceUrl, {
    ImportMetadata? importMetadata,
    UrlImportOptions? options,
    void Function(MediaTransferProgress progress)? onProgress,
  }) {
    return _activeRepository.importFromUrlIntoFolder(
      folder,
      sourceUrl,
      importMetadata: importMetadata,
      options: options,
      onProgress: onProgress,
    );
  }
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
    ImportMetadata? importMetadata,
    bool skipIfExists = true,
    void Function(MediaTransferProgress progress)? onProgress,
  }) {
    return _activeRepository.importItemsIntoFolder(
      dest,
      items,
      importMetadata: importMetadata,
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
