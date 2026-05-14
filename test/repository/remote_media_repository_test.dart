import 'dart:typed_data';

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/models/folder.dart';
import 'package:pdf_viewer/models/mediaItem.dart';
import 'package:pdf_viewer/models/metadata_settings.dart';
import 'package:pdf_viewer/models/tag.dart';
import 'package:pdf_viewer/repository/mediaRepository.dart';
import 'package:pdf_viewer/repository/remote_media_repository.dart';
import 'package:pdf_viewer/services/media_id_resolver.dart';
import 'package:pdf_viewer/services/remote_media_api_client.dart';

void main() {
  group('RemoteMediaRepository.rename', () {
    test(
      'returns the refreshed remote item after a successful rename',
      () async {
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

        apiClient.onRename = (afterItem) {
          apiClient.folderEntriesByFolder[afterItem.folderRaw] =
              <RemoteFolderEntry>[
                RemoteFolderEntry(
                  entryId: afterItem.id,
                  displayName: afterItem.displayName,
                  folderRaw: afterItem.folderRaw,
                  kind: 'image',
                  mediaId: afterItem.id,
                  fullPath: afterItem.id,
                  mimeType: 'image/jpeg',
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
        expect(
          idResolver.forgotten,
          containsAll(<String>[item.id, renamed.id]),
        );
      },
    );

    test('supports folder rename through the remote api', () async {
      final apiClient = _FakeRemoteMediaApiClient();
      final idResolver = _FakeMediaIdResolver();
      final repository = RemoteMediaRepository(
        apiClient: apiClient,
        idResolver: idResolver,
        localPickerRepository: const _StubMediaRepository(),
      );
      final item = MediaItem(
        id: r'C:\library\old-folder',
        displayName: 'old-folder',
        kind: MediaKind.folder,
        folderRaw: r'C:\library',
      );

      apiClient.onRename = (afterItem) {
        apiClient.folderEntriesByFolder[afterItem.folderRaw] =
            <RemoteFolderEntry>[
              RemoteFolderEntry(
                entryId: afterItem.id,
                displayName: afterItem.displayName,
                folderRaw: afterItem.folderRaw,
                kind: 'folder',
                mediaId: null,
                fullPath: afterItem.id,
                mimeType: null,
                sizeBytes: null,
                modifiedAt: null,
              ),
            ];
      };

      final renamed = await repository.rename(item, 'new-folder');

      expect(renamed.id, r'C:\library\new-folder');
      expect(renamed.displayName, 'new-folder');
      expect(renamed.kind, MediaKind.folder);
      expect(apiClient.renameCalls, hasLength(1));
      expect(apiClient.renameCalls.single.oldPath, item.id);
      expect(apiClient.renameCalls.single.newPath, r'C:\library\new-folder');
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

    test(
      'allows deleting remote folders without media verification lookup',
      () async {
        final apiClient = _FakeRemoteMediaApiClient();
        final idResolver = _FakeMediaIdResolver();
        final repository = RemoteMediaRepository(
          apiClient: apiClient,
          idResolver: idResolver,
          localPickerRepository: const _StubMediaRepository(),
        );
        final folderItem = MediaItem(
          id: r'C:\library\artist-folder',
          displayName: 'artist-folder',
          kind: MediaKind.folder,
          folderRaw: r'C:\library',
        );

        final deleted = await repository.deleteItem(folderItem);

        expect(deleted, isTrue);
        expect(apiClient.deleteCalls, hasLength(1));
        expect(apiClient.deleteCalls.single, <String>[
          'stable:${folderItem.id}',
        ]);
        expect(apiClient.metaRequests, isEmpty);
        expect(idResolver.forgotten, <String>[folderItem.id]);
      },
    );

    test('throws when the deletion cannot be verified', () async {
      final apiClient = _FakeRemoteMediaApiClient()
        ..markDeletedOnDelete = false;
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
            mimeType: 'image/jpeg',
            sizeBytes: 12,
            modifiedAt: DateTime.utc(2026, 3, 1),
          ),
        ];
      final repository = RemoteMediaRepository(
        apiClient: apiClient,
        idResolver: _FakeMediaIdResolver(),
        localPickerRepository: const _StubMediaRepository(),
      );

      final items = await repository.listMedia(
        const FolderHandle(r'C:\library'),
      );
      final pair = await repository.readThumbPair(items.single, maxWidth: 240);

      expect(pair.front, isNotEmpty);
      expect(apiClient.metaRequests, <String>['server-media-id']);
      expect(apiClient.thumbnailRequests, <String>['server-media-id']);
    });
  });

  group('RemoteMediaRepository.importFromUrlIntoFolder', () {
    test('forwards the URL import request to the host API', () async {
      final apiClient = _FakeRemoteMediaApiClient();
      apiClient.availableFolders = const <FolderHandle>[
        FolderHandle(r'D:\other'),
        FolderHandle(r'C:\host\library'),
      ];
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
      expect(
        apiClient.lastDownloadUrl,
        'https://kemono.su/patreon/user/123/post/456',
      );
      expect(apiClient.lastDownloadUrlMetadata?.artistTag, 'Artist');
      expect(apiClient.lastDownloadUrlMetadata?.seriesTag, 'Series');
      expect(apiClient.lastDownloadUrlMetadata?.freeTags, const <String>[
        'free-1',
      ]);
      expect(apiClient.lastDownloadUrlMetadata?.characterTags, const <String>[
        'heroine',
      ]);
      expect(apiClient.lastDownloadUrlMetadata?.targetCollection, 'library');
      expect(apiClient.lastDownloadUrlMetadata?.organizeAfterImport, isTrue);
    });

    test('uses the host library folder for library URL imports', () async {
      final apiClient = _FakeRemoteMediaApiClient();
      apiClient.availableFolders = const <FolderHandle>[
        FolderHandle(r'D:\archive'),
        FolderHandle(r'C:\Users\Host\Documents\library'),
        FolderHandle(r'E:\misc'),
      ];
      final repository = RemoteMediaRepository(
        apiClient: apiClient,
        idResolver: _FakeMediaIdResolver(),
        localPickerRepository: const _StubMediaRepository(),
      );

      final library = await repository.getAppLibraryFolder();
      await repository.importFromUrlIntoFolder(
        library,
        'https://kemono.su/patreon/user/123/post/456',
      );

      expect(library.raw, r'C:\Users\Host\Documents\library');
      expect(
        apiClient.lastDownloadUrlFolderRaw,
        r'C:\Users\Host\Documents\library',
      );
    });

    test(
      'falls back to client staging upload when the host downloader lacks requests',
      () async {
        final apiClient = _FakeRemoteMediaApiClient()
          ..downloadUrlError = const RemoteMediaException(
            "[stderr] ModuleNotFoundError: No module named 'requests'",
          );
        final localRepository = _RecordingLocalUrlImportRepository();
        final repository = RemoteMediaRepository(
          apiClient: apiClient,
          idResolver: _FakeMediaIdResolver(),
          localPickerRepository: localRepository,
        );
        final metadata = ImportMetadata(
          artistTag: 'Artist',
          targetCollection: 'library',
        );

        final result = await repository.importFromUrlIntoFolder(
          const FolderHandle(r'C:\Users\Host\Documents\library'),
          'https://kemono.su/patreon/user/123/post/456',
          importMetadata: metadata,
        );

        expect(
          apiClient.lastDownloadUrlFolderRaw,
          r'C:\Users\Host\Documents\library',
        );
        expect(
          localRepository.lastImportedUrl,
          'https://kemono.su/patreon/user/123/post/456',
        );
        expect(localRepository.lastImportedFolderRaw, isNotEmpty);
        expect(result.importedCount, 1);
        expect(result.skippedCount, 0);
        expect(result.failedCount, 0);
        expect(
          apiClient.lastUploadFolderRaw,
          r'C:\Users\Host\Documents\library',
        );
        expect(apiClient.lastUploadMetadata?.artistTag, 'Artist');
        expect(apiClient.lastUploadMetadata?.targetCollection, 'library');
        expect(apiClient.lastUploadFiles, hasLength(1));
        expect(apiClient.lastUploadFiles.single.fileName, 'downloaded.jpg');
      },
    );

    test(
      'prefers generated hitomi pdf and attaches inferred artist and series tags during fallback upload',
      () async {
        final apiClient = _FakeRemoteMediaApiClient()
          ..downloadUrlError = const RemoteMediaException(
            "[stderr] ModuleNotFoundError: No module named 'requests'",
          );
        final localRepository = _RecordingLocalUrlImportRepository(
          createHitomiPdfBundle: true,
        );
        final repository = RemoteMediaRepository(
          apiClient: apiClient,
          idResolver: _FakeMediaIdResolver(),
          localPickerRepository: localRepository,
        );

        final result = await repository.importFromUrlIntoFolder(
          const FolderHandle(r'C:\Users\Host\Documents\library'),
          'https://hitomi.la/reader/123456.html',
        );

        expect(result.importedCount, 1);
        expect(apiClient.lastUploadFiles, hasLength(1));
        expect(
          apiClient.lastUploadFiles.single.fileName,
          '[20241105] [3114110] Sample Title.pdf',
        );
        expect(
          apiClient.lastUploadFiles.single.tags
              .map((tag) => '${tag.category.name}:${tag.name}')
              .toSet(),
          containsAll(<String>{
            'artist:ArtistName',
            'artist:CoArtist',
            'series:Original Series',
            'mediaType:hitomi',
          }),
        );
      },
    );

    test('attaches ddd-smart media type to fallback-uploaded images', () async {
      final apiClient = _FakeRemoteMediaApiClient()
        ..downloadUrlError = const RemoteMediaException(
          "[stderr] ModuleNotFoundError: No module named 'requests'",
        );
      final localRepository = _RecordingLocalUrlImportRepository();
      final repository = RemoteMediaRepository(
        apiClient: apiClient,
        idResolver: _FakeMediaIdResolver(),
        localPickerRepository: localRepository,
      );

      final result = await repository.importFromUrlIntoFolder(
        const FolderHandle(r'C:\Users\Host\Documents\library'),
        'https://ddd-smart.net/doujinshi3/show-m.php?g=20260411&dir=0058&page=0',
      );

      expect(result.importedCount, 1);
      expect(apiClient.lastUploadFiles, hasLength(1));
      expect(apiClient.lastUploadFiles.single.fileName, 'downloaded.jpg');
      expect(
        apiClient.lastUploadFiles.single.tags
            .map((tag) => '${tag.category.name}:${tag.name}')
            .toSet(),
        contains('mediaType:ddd-smart'),
      );
    });

    test(
      'prefers client staging for ddd-smart urls even when host downloader is available',
      () async {
        final apiClient = _FakeRemoteMediaApiClient();
        final localRepository = _RecordingLocalUrlImportRepository();
        final repository = RemoteMediaRepository(
          apiClient: apiClient,
          idResolver: _FakeMediaIdResolver(),
          localPickerRepository: localRepository,
        );

        final result = await repository.importFromUrlIntoFolder(
          const FolderHandle(r'C:\Users\Host\Documents\library'),
          'https://ddd-smart.net/doujinshi3/show-m.php?g=20260411&dir=005&page=0',
        );

        expect(result.importedCount, 1);
        expect(apiClient.lastDownloadUrlFolderRaw, isNull);
        expect(
          localRepository.lastImportedUrl,
          'https://ddd-smart.net/doujinshi3/show-m.php?g=20260411&dir=005&page=0',
        );
        expect(apiClient.lastUploadFiles, hasLength(1));
        expect(
          apiClient.lastUploadFiles.single.tags
              .map((tag) => '${tag.category.name}:${tag.name}')
              .toSet(),
          contains('mediaType:ddd-smart'),
        );
      },
    );
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
      expect(apiClient.lastUploadMetadata?.freeTags, const <String>[
        'free-1',
        'free-2',
      ]);
      expect(apiClient.lastUploadMetadata?.characterTags, const <String>[
        'heroine',
      ]);
      expect(apiClient.lastUploadMetadata?.targetCollection, 'library');
      expect(apiClient.lastUploadMetadata?.organizeAfterImport, isTrue);
      expect(apiClient.lastUploadFiles, hasLength(1));
      expect(apiClient.lastUploadFiles.single.fileName, 'old.jpg');
    });

    test(
      'includes locally stored tags using the normalized upload path key',
      () async {
        final apiClient = _FakeRemoteMediaApiClient();
        final tempDir = await Directory.systemTemp.createTemp(
          'remote-upload-tags',
        );
        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final sourceFile = File(
          '${tempDir.path}${Platform.pathSeparator}old.jpg',
        );
        await sourceFile.writeAsBytes(<int>[1, 2, 3], flush: true);
        final repository = RemoteMediaRepository(
          apiClient: apiClient,
          idResolver: _FakeMediaIdResolver(),
          localPickerRepository: const _StubMediaRepository(),
          localUploadTagsProvider: (_) async => <String, List<Tag>>{
            sourceFile.path: const <Tag>[
              Tag(name: 'Agua Larson', category: TagCategory.artist),
              Tag(name: 'Summer Line', category: TagCategory.series),
              Tag(name: 'Heroine X', category: TagCategory.character),
              Tag(name: 'bonus', category: TagCategory.free),
            ],
          },
        );

        final importedCount = await repository.importItemsIntoFolder(
          const FolderHandle(r'C:\library'),
          <MediaItem>[
            MediaItem(
              id: sourceFile.uri.toString(),
              displayName: 'old.jpg',
              kind: MediaKind.image,
              folderRaw: tempDir.path,
            ),
          ],
        );

        expect(importedCount, 1);
        expect(apiClient.lastUploadFiles, hasLength(1));
        expect(
          apiClient.lastUploadFiles.single.tags
              .map((tag) => '${tag.category.name}:${tag.name}')
              .toSet(),
          <String>{
            'artist:Agua Larson',
            'series:Summer Line',
            'character:Heroine X',
            'free:bonus',
          },
        );
      },
    );
  });

  group('Repository capabilities', () {
    test(
      'SwitchingMediaRepository exposes the active repository capabilities',
      () {
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
      },
    );
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

  const _RenameCall({required this.oldPath, required this.newPath});
}

class _FakeRemoteMediaApiClient extends RemoteMediaApiClient {
  List<FolderHandle> availableFolders = const <FolderHandle>[];
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
  Object? downloadUrlError;
  bool markDeletedOnDelete = true;
  void Function(MediaItem afterItem)? onRename;

  _FakeRemoteMediaApiClient() : super(baseUrl: 'http://example.com');

  @override
  Future<List<FolderHandle>> listAvailableFolders() async => availableFolders;

  @override
  Future<void> renameMedia({
    required MediaItem beforeItem,
    required MediaItem afterItem,
    required ResolvedMediaIdentity beforeIdentity,
  }) async {
    final error = renameError;
    if (error != null) {
      throw error;
    }
    renameCalls.add(_RenameCall(oldPath: beforeItem.id, newPath: afterItem.id));
    onRename?.call(afterItem);
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
    final entries =
        folderEntriesByFolder[folderRaw] ?? const <RemoteFolderEntry>[];
    final paged = entries.skip(offset).take(limit).toList(growable: false);
    return RemoteFolderPage(
      items: paged,
      total: entries.length,
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<RemoteMediaMeta> fetchMediaMeta(
    String mediaId, {
    ResolvedMediaIdentity? identity,
  }) async {
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
      pageCount: null,
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
    void Function(MediaTransferProgress progress)? onProgress,
  }) async {
    lastDownloadUrlFolderRaw = folderRaw;
    lastDownloadUrl = sourceUrl;
    lastDownloadUrlMetadata = importMetadata;
    lastDownloadUrlOptions = options;
    final error = downloadUrlError;
    if (error != null) {
      throw error;
    }
    return const UrlImportResult(importedCount: 3, skippedCount: 1);
  }

  @override
  Future<RemoteUploadResponse> uploadFiles({
    required String folderRaw,
    required List<RemoteUploadFile> files,
    ImportMetadata? importMetadata,
    bool skipIfExists = true,
    void Function(MediaTransferProgress progress)? onProgress,
    String? requestId,
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

class _RecordingLocalUrlImportRepository extends _StubMediaRepository {
  final bool createHitomiPdfBundle;
  String? lastImportedFolderRaw;
  String? lastImportedUrl;

  _RecordingLocalUrlImportRepository({this.createHitomiPdfBundle = false});

  @override
  bool get canImportFromUrl => true;

  @override
  Future<UrlImportResult> importFromUrlIntoFolder(
    FolderHandle folder,
    String sourceUrl, {
    ImportMetadata? importMetadata,
    UrlImportOptions? options,
    void Function(MediaTransferProgress progress)? onProgress,
  }) async {
    lastImportedFolderRaw = folder.raw;
    lastImportedUrl = sourceUrl;
    if (createHitomiPdfBundle) {
      final galleryDir = Directory(
        '${folder.raw}${Platform.pathSeparator}hitomi${Platform.pathSeparator}[12345] ArtistName${Platform.pathSeparator}[20241105] [3114110] Sample Title',
      );
      await galleryDir.create(recursive: true);
      await File(
        '${galleryDir.path}${Platform.pathSeparator}001.jpg',
      ).writeAsBytes(<int>[1, 2, 3], flush: true);
      await File(
        '${galleryDir.parent.path}${Platform.pathSeparator}[20241105] [3114110] Sample Title.pdf',
      ).writeAsBytes(<int>[37, 80, 68, 70], flush: true);
    } else {
      final file = File('${folder.raw}${Platform.pathSeparator}downloaded.jpg');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(<int>[1, 2, 3], flush: true);
    }
    final hitomiMetadataByRelativePath = createHitomiPdfBundle
        ? <String, HitomiGalleryMetadata>{
            HitomiGalleryMetadata.normalizeRelativePathKey(
              'hitomi/[12345] ArtistName/[20241105] [3114110] Sample Title.pdf',
            )!: const HitomiGalleryMetadata(
              artists: <String>['ArtistName', 'CoArtist'],
              series: <String>['Original Series'],
            ),
          }
        : const <String, HitomiGalleryMetadata>{};
    return UrlImportResult(
      importedCount: 1,
      hitomiMetadataByRelativePath: hitomiMetadataByRelativePath,
    );
  }

  @override
  Future<List<MediaItem>> listMediaRecursiveFiles(
    FolderHandle folder, {
    void Function(int processed, int total)? onProgress,
  }) async {
    final rootDir = Directory(folder.raw);
    if (!await rootDir.exists()) {
      return const <MediaItem>[];
    }
    final items = <MediaItem>[];
    await for (final entity in rootDir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) {
        continue;
      }
      final stat = await entity.stat();
      final name = entity.uri.pathSegments.isNotEmpty
          ? entity.uri.pathSegments.last
          : entity.path;
      final lowerName = name.toLowerCase();
      final kind = lowerName.endsWith('.pdf') ? MediaKind.pdf : MediaKind.image;
      items.add(
        MediaItem(
          id: entity.path,
          displayName: name,
          kind: kind,
          folderRaw: entity.parent.path,
          modified: stat.modified,
          sizeBytes: stat.size,
        ),
      );
    }
    return items;
  }

  @override
  Future<Uint8List> readBytes(MediaItem item) async {
    return File(item.id).readAsBytes();
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
    // ignore: unused_element_parameter
    this.appMode = AppMode.standalone,
  });

  @override
  Future<void> reloadSettings() async {}

  @override
  Future<List<FolderHandle>> listAvailableFolders() async =>
      const <FolderHandle>[];

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
  Future<List<MediaItem>> pickExternalMediaFolderItems({
    void Function(int processed, int total)? onProgress,
  }) async => const <MediaItem>[];

  @override
  Future<List<MediaItem>> resolveExternalItems(List<String> rawItems) async {
    return const <MediaItem>[];
  }

  @override
  Future<FolderHandle> getAppLibraryFolder() async =>
      const FolderHandle(r'C:\library');

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
  Future<Uint8List> readPdfSourceBytes(
    MediaItem item, {
    int maxWidth = 2800,
  }) async => Uint8List(0);

  @override
  Future<int> getPageCount(MediaItem item) async => 1;

  @override
  Future<Uint8List> renderPageBytes(
    MediaItem item,
    int page, {
    int maxWidth = 1600,
  }) async => Uint8List(0);

  @override
  Future<Uint8List> renderStaticPageBytes(
    MediaItem item,
    int page, {
    int maxWidth = 1600,
  }) async => Uint8List(0);

  @override
  Future<bool> deleteItem(MediaItem item) async => false;

  @override
  Future<int> deleteItems(List<MediaItem> items) async => 0;

  @override
  Future<MediaItem> deletePdfPage(MediaItem item, int pageNumber) async => item;

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
