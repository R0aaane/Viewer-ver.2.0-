import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/models/folder.dart';
import 'package:pdf_viewer/models/mediaItem.dart';
import 'package:pdf_viewer/models/metadata_settings.dart';
import 'package:pdf_viewer/repository/mediaRepository.dart';
import 'package:pdf_viewer/repository/remote_media_repository.dart';
import 'package:pdf_viewer/services/media_id_resolver.dart';
import 'package:pdf_viewer/services/remote_media_api_client.dart';

void main() {
  group('RemoteMediaRepository.rename', () {
    test('returns the refreshed remote item after a successful rename', () async {
      final apiClient = _FakeRemoteMediaApiClient();
      final idResolver = _FakeMediaIdResolver();
      final repository = RemoteMediaRepository(
        apiClient: apiClient,
        idResolver: idResolver,
        localPickerRepository: const _StubMediaRepository(),
      );
      final item = _imageItem(
        id: r'C:\library\old.jpg',
        displayName: 'old.jpg',
      );

      apiClient.onRename = (afterItem, afterIdentity) {
        apiClient.folderEntriesByFolder[afterItem.folderRaw] = <RemoteFolderEntry>[
          RemoteFolderEntry(
            entryId: afterItem.id,
            displayName: afterItem.displayName,
            folderRaw: afterItem.folderRaw,
            kind: 'image',
            mediaId: afterIdentity.stableId,
            fullPath: afterItem.id,
            sizeBytes: afterItem.sizeBytes,
            modifiedAt: afterItem.modified,
          ),
        ];
      };

      final renamed = await repository.rename(item, 'new');

      expect(renamed.id, r'C:\library\new.jpg');
      expect(renamed.displayName, 'new.jpg');
      expect(renamed.kind, MediaKind.image);
      expect(apiClient.renameCalls, hasLength(1));
      expect(apiClient.renameCalls.single.oldPath, item.id);
      expect(apiClient.renameCalls.single.newPath, r'C:\library\new.jpg');
      expect(idResolver.forgotten, containsAll(<String>[item.id, renamed.id]));
    });

    test('throws when the remote rename API fails', () async {
      final apiClient = _FakeRemoteMediaApiClient()
        ..renameError = const RemoteMediaException('rename failed');
      final repository = RemoteMediaRepository(
        apiClient: apiClient,
        idResolver: _FakeMediaIdResolver(),
        localPickerRepository: const _StubMediaRepository(),
      );

      expect(
        () => repository.rename(_imageItem(), 'new'),
        throwsA(
          isA<RemoteMediaException>().having(
            (error) => error.message,
            'message',
            'rename failed',
          ),
        ),
      );
    });
  });

  group('RemoteMediaRepository.deleteItem', () {
    test('returns true only after the remote deletion is confirmed', () async {
      final apiClient = _FakeRemoteMediaApiClient();
      final idResolver = _FakeMediaIdResolver();
      final repository = RemoteMediaRepository(
        apiClient: apiClient,
        idResolver: idResolver,
        localPickerRepository: const _StubMediaRepository(),
      );
      final item = _imageItem();

      final deleted = await repository.deleteItem(item);

      expect(deleted, isTrue);
      expect(apiClient.deleteCalls, hasLength(1));
      expect(apiClient.deleteCalls.single, <String>['stable:${item.id}']);
      expect(idResolver.forgotten, <String>[item.id]);
    });

    test('throws when the deletion cannot be verified', () async {
      final apiClient = _FakeRemoteMediaApiClient()..markDeletedOnDelete = false;
      final repository = RemoteMediaRepository(
        apiClient: apiClient,
        idResolver: _FakeMediaIdResolver(),
        localPickerRepository: const _StubMediaRepository(),
      );

      expect(
        () => repository.deleteItem(_imageItem()),
        throwsA(
          isA<RemoteMediaException>().having(
            (error) => error.message,
            'message',
            contains('削除結果を確認できませんでした'),
          ),
        ),
      );
    });
  });

  group('RemoteMediaRepository.readThumbPair', () {
    test('uses the server mediaId remembered from folder entries', () async {
      final apiClient = _FakeRemoteMediaApiClient()
        ..folderEntriesByFolder[r'C:\library'] = <RemoteFolderEntry>[
          RemoteFolderEntry(
            entryId: r'C:\library\old.jpg',
            displayName: 'old.jpg',
            folderRaw: r'C:\library',
            kind: 'image',
            mediaId: 'server-media-id',
            fullPath: r'C:\library\old.jpg',
            sizeBytes: 12,
            modifiedAt: DateTime.utc(2026, 3, 1),
          ),
        ];
      final repository = RemoteMediaRepository(
        apiClient: apiClient,
        idResolver: _FakeMediaIdResolver(),
        localPickerRepository: const _StubMediaRepository(),
      );

      final items = await repository.listMedia(const FolderHandle(r'C:\library'));
      final pair = await repository.readThumbPair(items.single, maxWidth: 240);

      expect(pair.front, isNotEmpty);
      expect(apiClient.metaRequests, <String>['server-media-id']);
      expect(apiClient.thumbnailRequests, <String>['server-media-id']);
    });
  });

  group('RemoteMediaRepository.importFromUrlIntoFolder', () {
    test('forwards the URL import request to the host API', () async {
      final apiClient = _FakeRemoteMediaApiClient();
      final repository = RemoteMediaRepository(
        apiClient: apiClient,
        idResolver: _FakeMediaIdResolver(),
        localPickerRepository: const _StubMediaRepository(),
      );
      final metadata = ImportMetadata(
        artistTag: 'Artist',
        seriesTag: 'Series',
        freeTags: const <String>['free-1'],
        characterTags: const <String>['heroine'],
        targetCollection: 'library',
        organizeAfterImport: true,
      );

      final result = await repository.importFromUrlIntoFolder(
        const FolderHandle(r'C:\library'),
        'https://kemono.su/patreon/user/123/post/456',
        importMetadata: metadata,
      );

      expect(result.importedCount, 3);
      expect(result.skippedCount, 1);
      expect(result.failedCount, 0);
      expect(apiClient.lastDownloadUrlFolderRaw, r'C:\library');
      expect(apiClient.lastDownloadUrl, 'https://kemono.su/patreon/user/123/post/456');
      expect(apiClient.lastDownloadUrlMetadata?.artistTag, 'Artist');
      expect(apiClient.lastDownloadUrlMetadata?.seriesTag, 'Series');
      expect(apiClient.lastDownloadUrlMetadata?.freeTags, const <String>['free-1']);
      expect(apiClient.lastDownloadUrlMetadata?.characterTags, const <String>['heroine']);
      expect(apiClient.lastDownloadUrlMetadata?.targetCollection, 'library');
      expect(apiClient.lastDownloadUrlMetadata?.organizeAfterImport, isTrue);
    });
  });
  group('RemoteMediaRepository.importItemsIntoFolder', () {
    test('forwards import metadata to the upload api', () async {
      final apiClient = _FakeRemoteMediaApiClient();
      final repository = RemoteMediaRepository(
        apiClient: apiClient,
        idResolver: _FakeMediaIdResolver(),
        localPickerRepository: const _StubMediaRepository(),
      );
      final metadata = ImportMetadata(
        artistTag: 'Artist',
        seriesTag: 'Series',
        freeTags: const <String>['free-1', 'free-2'],
        characterTags: const <String>['heroine'],
        targetCollection: 'library',
        organizeAfterImport: true,
      );

      final importedCount = await repository.importItemsIntoFolder(
        const FolderHandle(r'C:\library'),
        <MediaItem>[_imageItem()],
        importMetadata: metadata,
      );

      expect(importedCount, 1);
      expect(apiClient.lastUploadFolderRaw, r'C:\library');
      expect(apiClient.lastUploadMetadata?.artistTag, 'Artist');
      expect(apiClient.lastUploadMetadata?.seriesTag, 'Series');
      expect(
        apiClient.lastUploadMetadata?.freeTags,
        const <String>['free-1', 'free-2'],
      );
      expect(
        apiClient.lastUploadMetadata?.characterTags,
        const <String>['heroine'],
      );
      expect(apiClient.lastUploadMetadata?.targetCollection, 'library');
      expect(apiClient.lastUploadMetadata?.organizeAfterImport, isTrue);
      expect(apiClient.lastUploadFiles, hasLength(1));
      expect(apiClient.lastUploadFiles.single.fileName, 'old.jpg');
    });
  });

  group('Repository capabilities', () {
    test('SwitchingMediaRepository exposes the active repository capabilities', () {
      const localCapabilities = RepositoryCapabilities(
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
      const localRepository = _StubMediaRepository(
        capabilities: localCapabilities,
      );

      final standalone = SwitchingMediaRepository(
        localRepository,
        initialSettings: const MetadataSettings(appMode: AppMode.standalone),
      );
      final remote = SwitchingMediaRepository(
        localRepository,
        initialSettings: const MetadataSettings(
          appMode: AppMode.client,
          clientApiBaseUrl: 'http://example.com',
        ),
      );

      expect(standalone.capabilities.canExportPdf, isTrue);
      expect(standalone.capabilities.canOrganizeLibrary, isTrue);
      expect(standalone.capabilities.canPickFolder, isTrue);
      expect(standalone.capabilities.canAddLocalFolder, isTrue);
      expect(standalone.capabilities.canImportToHost, isFalse);
      expect(remote.capabilities.canUpload, isTrue);
      expect(remote.capabilities.canExportPdf, isFalse);
      expect(remote.capabilities.canOrganizeLibrary, isFalse);
      expect(remote.capabilities.canPickFolder, isFalse);
      expect(remote.capabilities.canAddLocalFolder, isFalse);
      expect(remote.capabilities.canImportToHost, isTrue);
      expect(remote.capabilities.canAssignImportTags, isTrue);
    });
  });
}

MediaItem _imageItem({
  String id = r'C:\library\old.jpg',
  String displayName = 'old.jpg',
}) {
  return MediaItem(
    id: id,
    displayName: displayName,
    kind: MediaKind.image,
    folderRaw: r'C:\library',
    modified: DateTime.utc(2026, 3, 1),
    sizeBytes: 12,
  );
}

class _RenameCall {
  final String oldPath;
  final String newPath;

  const _RenameCall({
    required this.oldPath,
    required this.newPath,
  });
}

class _FakeRemoteMediaApiClient extends RemoteMediaApiClient {
  final Map<String, List<RemoteFolderEntry>> folderEntriesByFolder =
      <String, List<RemoteFolderEntry>>{};
  final List<_RenameCall> renameCalls = <_RenameCall>[];
  final List<List<String>> deleteCalls = <List<String>>[];
  final Set<String> _deletedStableIds = <String>{};
  final List<String> metaRequests = <String>[];
  final List<String> thumbnailRequests = <String>[];
  String? lastUploadFolderRaw;
  List<RemoteUploadFile> lastUploadFiles = const <RemoteUploadFile>[];
  ImportMetadata? lastUploadMetadata;
  String? lastDownloadUrlFolderRaw;
  String? lastDownloadUrl;
  ImportMetadata? lastDownloadUrlMetadata;
  UrlImportOptions? lastDownloadUrlOptions;

  Object? renameError;
  Object? deleteError;
  bool markDeletedOnDelete = true;
  void Function(MediaItem afterItem, ResolvedMediaIdentity afterIdentity)?
      onRename;

  _FakeRemoteMediaApiClient() : super(baseUrl: 'http://example.com');

  @override
  Future<void> renameMedia({
    required MediaItem beforeItem,
    required MediaItem afterItem,
    required ResolvedMediaIdentity beforeIdentity,
    required ResolvedMediaIdentity afterIdentity,
  }) async {
    final error = renameError;
    if (error != null) {
      throw error;
    }
    renameCalls.add(_RenameCall(oldPath: beforeItem.id, newPath: afterItem.id));
    onRename?.call(afterItem, afterIdentity);
  }

  @override
  Future<void> deleteMedia(
    List<(MediaItem, ResolvedMediaIdentity)> items, {
    required bool hardDelete,
  }) async {
    final error = deleteError;
    if (error != null) {
      throw error;
    }
    final ids = items.map((entry) => entry.$2.stableId).toList(growable: false);
    deleteCalls.add(ids);
    if (markDeletedOnDelete) {
      _deletedStableIds.addAll(ids);
    }
  }

  @override
  Future<RemoteFolderPage> listFolderChildren(
    String folderRaw, {
    int limit = 100,
    int offset = 0,
  }) async {
    final entries = folderEntriesByFolder[folderRaw] ?? const <RemoteFolderEntry>[];
    final paged = entries.skip(offset).take(limit).toList(growable: false);
    return RemoteFolderPage(
      items: paged,
      total: entries.length,
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<RemoteMediaMeta> fetchMediaMeta(String mediaId) async {
    metaRequests.add(mediaId);
    if (_deletedStableIds.contains(mediaId)) {
      throw const RemoteMediaException('not found', statusCode: 404);
    }
    return RemoteMediaMeta(
      mediaId: mediaId,
      displayName: 'item.jpg',
      kind: 'image',
      mimeType: 'image/jpeg',
      sizeBytes: 12,
      modifiedAt: DateTime.utc(2026, 3, 1),
      etag: 'etag',
      supportsRange: true,
    );
  }

  @override
  Future<Uint8List> fetchThumbnail(
    String mediaId, {
    int? width,
    int? height,
    int? page,
  }) async {
    thumbnailRequests.add(mediaId);
    return Uint8List.fromList(<int>[1, 2, 3]);
  }

  @override
  Future<UrlImportResult> downloadUrl({
    required String folderRaw,
    required String sourceUrl,
    ImportMetadata? importMetadata,
    UrlImportOptions? options,
  }) async {
    lastDownloadUrlFolderRaw = folderRaw;
    lastDownloadUrl = sourceUrl;
    lastDownloadUrlMetadata = importMetadata;
    lastDownloadUrlOptions = options;
    return const UrlImportResult(importedCount: 3, skippedCount: 1);
  }
  @override
  Future<RemoteUploadResponse> uploadFiles({
    required String folderRaw,
    required List<RemoteUploadFile> files,
    ImportMetadata? importMetadata,
    bool skipIfExists = true,
    void Function(MediaTransferProgress progress)? onProgress,
  }) async {
    lastUploadFolderRaw = folderRaw;
    lastUploadFiles = files;
    lastUploadMetadata = importMetadata;
    return const RemoteUploadResponse(importedCount: 1, skippedCount: 0);
  }
}

class _FakeMediaIdResolver extends MediaIdResolver {
  final List<String> forgotten = <String>[];

  @override
  Future<ResolvedMediaIdentity> resolve(MediaItem item) async {
    return ResolvedMediaIdentity(
      stableId: 'stable:${item.id}',
      aliases: <String>[item.id],
      sizeBytes: item.sizeBytes,
      modifiedEpochMs: item.modified?.millisecondsSinceEpoch,
      normalizedPath: item.id,
      relativePathHint: item.displayName,
    );
  }

  @override
  void forget(MediaItem item) {
    forgotten.add(item.id);
  }
}

class _StubMediaRepository implements MediaRepository {
  @override
  final RepositoryCapabilities capabilities;

  @override
  final AppMode appMode;

  @override
  bool get isRemoteMode => appMode == AppMode.client;

  @override
  bool get isHostMode => appMode == AppMode.host;

  @override
  bool get canImportFromUrl => false;

  const _StubMediaRepository({
    this.capabilities = const RepositoryCapabilities(
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
    ),
    this.appMode = AppMode.standalone,
  });

  @override
  Future<void> reloadSettings() async {}

  @override
  Future<List<FolderHandle>> listAvailableFolders() async => const <FolderHandle>[];

  @override
  Future<FolderHandle?> pickFolder() async => null;

  @override
  Future<MediaItem?> pickSinglePdf() async => null;

  @override
  Future<List<MediaItem>> pickExternalMediaFiles({
    bool allowMultiple = true,
    bool includeImages = true,
    bool includePdf = true,
  }) async => const <MediaItem>[];

  @override
  Future<List<MediaItem>> resolveExternalItems(List<String> rawItems) async {
    return const <MediaItem>[];
  }

  @override
  Future<FolderHandle> getAppLibraryFolder() async => const FolderHandle(r'C:\library');

  @override
  Future<List<MediaItem>> listMedia(
    FolderHandle folder, {
    void Function(int processed, int total)? onProgress,
  }) async => const <MediaItem>[];

  @override
  Future<int> importIntoFolder(
    FolderHandle folder, {
    ImportRequest? request,
    void Function(MediaTransferProgress progress)? onProgress,
  }) async => 0;

  @override
  Future<UrlImportResult> importFromUrlIntoFolder(
    FolderHandle folder,
    String sourceUrl, {
    ImportMetadata? importMetadata,
    UrlImportOptions? options,
    void Function(MediaTransferProgress progress)? onProgress,
  }) async => const UrlImportResult(importedCount: 0);

  @override
  Future<ThumbPair> readThumbPair(MediaItem item, {int maxWidth = 360}) async {
    return ThumbPair(front: Uint8List(0));
  }

  @override
  Future<Uint8List> readBytes(MediaItem item) async => Uint8List(0);

  @override
  Future<int> getPageCount(MediaItem item) async => 1;

  @override
  Future<Uint8List> renderPageBytes(
    MediaItem item,
    int page, {
    int maxWidth = 1600,
  }) async => Uint8List(0);

  @override
  Future<bool> deleteItem(MediaItem item) async => false;

  @override
  Future<int> deleteItems(List<MediaItem> items) async => 0;

  @override
  Future<MediaItem> rename(MediaItem item, String newDisplayName) async => item;

  @override
  Future<int> importItemsIntoFolder(
    FolderHandle dest,
    List<MediaItem> items, {
    ImportMetadata? importMetadata,
    bool skipIfExists = true,
    void Function(MediaTransferProgress progress)? onProgress,
  }) async => 0;

  @override
  Future<List<MediaItem>> listMediaRecursiveFiles(
    FolderHandle folder, {
    void Function(int processed, int total)? onProgress,
  }) async => const <MediaItem>[];

  @override
  Future<int> countMedia(FolderHandle folder) async => 0;

  @override
  Future<PagedMediaResult> listMediaPage(
    FolderHandle folder, {
    required int offset,
    required int limit,
    void Function(int processed, int total)? onProgress,
  }) async => const PagedMediaResult(items: <MediaItem>[], total: 0);
}




