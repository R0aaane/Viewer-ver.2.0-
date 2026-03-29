import 'dart:typed_data';

import '../models/folder.dart';
import '../models/mediaItem.dart';
import '../models/metadata_settings.dart';

class RepositoryCapabilities {
  final bool canRename;
  final bool canDelete;
  final bool canUpload;
  final bool canRecursiveSearch;
  final bool canExportPdf;
  final bool canOrganizeLibrary;
  final bool canPickFolder;
  final bool canAddLocalFolder;
  final bool canImportToHost;
  final bool canBatchUpload;
  final bool canAssignImportTags;

  const RepositoryCapabilities({
    required this.canRename,
    required this.canDelete,
    required this.canUpload,
    required this.canRecursiveSearch,
    required this.canExportPdf,
    required this.canOrganizeLibrary,
    required this.canPickFolder,
    required this.canAddLocalFolder,
    required this.canImportToHost,
    required this.canBatchUpload,
    required this.canAssignImportTags,
  });
}

enum ImportSourceKind {
  files,
  folder,
}

class ImportMetadata {
  final String? artistTag;
  final String? seriesTag;
  final List<String> freeTags;
  final List<String> characterTags;
  final String? targetCollection;
  final bool organizeAfterImport;

  const ImportMetadata({
    this.artistTag,
    this.seriesTag,
    this.freeTags = const <String>[],
    this.characterTags = const <String>[],
    this.targetCollection,
    this.organizeAfterImport = false,
  });

  bool get hasAssignedTags {
    return (artistTag?.trim().isNotEmpty ?? false) ||
        (seriesTag?.trim().isNotEmpty ?? false) ||
        freeTags.isNotEmpty ||
        characterTags.isNotEmpty;
  }
}

class ImportRequest {
  final ImportSourceKind sourceKind;
  final bool skipIfExists;
  final ImportMetadata metadata;

  const ImportRequest({
    this.sourceKind = ImportSourceKind.files,
    this.skipIfExists = true,
    this.metadata = const ImportMetadata(),
  });
}

class ThumbPair {
  final Uint8List front;
  final Uint8List? back;

  const ThumbPair({required this.front, this.back});
}

class PagedMediaResult {
  final List<MediaItem> items;
  final int total;

  const PagedMediaResult({required this.items, required this.total});
}

class MediaTransferProgress {
  final int sentBytes;
  final int totalBytes;
  final int completedFiles;
  final int totalFiles;
  final String? currentFileName;

  const MediaTransferProgress({
    required this.sentBytes,
    required this.totalBytes,
    required this.completedFiles,
    required this.totalFiles,
    this.currentFileName,
  });

  double get fraction {
    if (totalBytes <= 0) {
      return 0;
    }
    return sentBytes / totalBytes;
  }
}

abstract class MediaRepository {
  RepositoryCapabilities get capabilities;

  AppMode get appMode => AppMode.standalone;

  bool get isRemoteMode => appMode == AppMode.client;
  bool get isHostMode => appMode == AppMode.host;

  Future<void> reloadSettings() async {}

  Future<List<FolderHandle>> listAvailableFolders() async =>
      const <FolderHandle>[];

  Future<FolderHandle?> pickFolder();
  Future<MediaItem?> pickSinglePdf();
  Future<List<MediaItem>> pickExternalMediaFiles({
    bool allowMultiple = true,
    bool includeImages = true,
    bool includePdf = true,
  });
  Future<List<MediaItem>> resolveExternalItems(List<String> rawItems);

  Future<FolderHandle> getAppLibraryFolder();

  Future<List<MediaItem>> listMedia(
    FolderHandle folder, {
    void Function(int processed, int total)? onProgress,
  });

  Future<int> importIntoFolder(
    FolderHandle folder, {
    ImportRequest? request,
    void Function(MediaTransferProgress progress)? onProgress,
  });

  Future<ThumbPair> readThumbPair(MediaItem item, {int maxWidth = 360});

  Future<Uint8List> readBytes(MediaItem item);

  Future<int> getPageCount(MediaItem item);

  Future<Uint8List> renderPageBytes(
    MediaItem item,
    int page, {
    int maxWidth = 1600,
  });

  Future<bool> deleteItem(MediaItem item);

  Future<int> deleteItems(List<MediaItem> items);

  Future<MediaItem> rename(MediaItem item, String newDisplayName);

  Future<int> importItemsIntoFolder(
    FolderHandle dest,
    List<MediaItem> items, {
    ImportMetadata? importMetadata,
    bool skipIfExists = true,
    void Function(MediaTransferProgress progress)? onProgress,
  });

  Future<List<MediaItem>> listMediaRecursiveFiles(
    FolderHandle folder, {
    void Function(int processed, int total)? onProgress,
  });

  Future<int> countMedia(FolderHandle folder);

  Future<PagedMediaResult> listMediaPage(
    FolderHandle folder, {
    required int offset,
    required int limit,
    void Function(int processed, int total)? onProgress,
  });
}
