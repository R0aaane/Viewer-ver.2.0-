import 'dart:typed_data';

import '../models/folder.dart';
import '../models/mediaItem.dart';
import '../models/metadata_settings.dart';
import '../models/tag.dart';

typedef LocalUploadTagsProvider =
    Future<Map<String, List<Tag>>> Function(List<MediaItem> items);

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

class UrlImportResult {
  final int importedCount;
  final int skippedCount;
  final int failedCount;

  const UrlImportResult({
    required this.importedCount,
    this.skippedCount = 0,
    this.failedCount = 0,
  });

  bool get hasChanges => importedCount > 0;
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

enum UrlImportMediaType {
  images,
  videos,
  imagesVideos,
  all,
}

extension UrlImportMediaTypeValue on UrlImportMediaType {
  String get apiValue => switch (this) {
    UrlImportMediaType.images => 'images',
    UrlImportMediaType.videos => 'videos',
    UrlImportMediaType.imagesVideos => 'images_videos',
    UrlImportMediaType.all => 'all',
  };
}

enum UrlImportCookieMode {
  auto,
  none,
  projectKemono,
  projectCoomer,
  projectCombined,
  customFile,
}

extension UrlImportCookieModeValue on UrlImportCookieMode {
  String get apiValue => switch (this) {
    UrlImportCookieMode.auto => 'auto',
    UrlImportCookieMode.none => 'none',
    UrlImportCookieMode.projectKemono => 'project_kemono',
    UrlImportCookieMode.projectCoomer => 'project_coomer',
    UrlImportCookieMode.projectCombined => 'project_combined',
    UrlImportCookieMode.customFile => 'custom',
  };
}

class UrlImportOptions {
  final UrlImportCookieMode cookieMode;
  final String? cookieFilePath;
  final String? urlListFilePath;
  final List<String> favoriteSites;
  final bool favoritePosts;
  final List<String> favoriteUserServices;
  final UrlImportMediaType mediaType;
  final int parallelDownloads;
  final bool includeInlineImages;
  final bool includePostContent;
  final bool includeComments;
  final bool saveJson;
  final bool overwriteExistingFiles;
  final bool verbose;
  final bool convertHitomiToPdf;

  const UrlImportOptions({
    this.cookieMode = UrlImportCookieMode.auto,
    this.cookieFilePath,
    this.urlListFilePath,
    this.favoriteSites = const <String>[],
    this.favoritePosts = false,
    this.favoriteUserServices = const <String>[],
    this.mediaType = UrlImportMediaType.all,
    this.parallelDownloads = 6,
    this.includeInlineImages = false,
    this.includePostContent = false,
    this.includeComments = false,
    this.saveJson = false,
    this.overwriteExistingFiles = false,
    this.verbose = false,
    this.convertHitomiToPdf = true,
  });

  List<String> collectSourceUrls(String sourceUrl) {
    final urls = <String>[];
    final seen = <String>{};
    for (final segment in sourceUrl.split(RegExp(r'[\r\n,]+'))) {
      final trimmed = segment.trim();
      if (trimmed.isEmpty) continue;
      if (seen.add(trimmed)) {
        urls.add(trimmed);
      }
    }
    return urls;
  }

  String? get normalizedCookieFilePath {
    final trimmed = cookieFilePath?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    return trimmed;
  }

  String? get normalizedUrlListFilePath {
    final trimmed = urlListFilePath?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    return trimmed;
  }

  List<String> get normalizedFavoriteSites {
    final sites = <String>[];
    final seen = <String>{};
    for (final site in favoriteSites) {
      final normalized = site.trim().toLowerCase();
      if (normalized.isEmpty) continue;
      if (seen.add(normalized)) {
        sites.add(normalized);
      }
    }
    return sites;
  }

  List<String> get normalizedFavoriteUserServices {
    final services = <String>[];
    final seen = <String>{};
    for (final service in favoriteUserServices) {
      final normalized = service.trim().toLowerCase();
      if (normalized.isEmpty) continue;
      if (seen.add(normalized)) {
        services.add(normalized);
      }
    }
    return services;
  }

  bool get hasFavoriteTargets {
    return favoritePosts || normalizedFavoriteUserServices.isNotEmpty;
  }

  bool get usesCustomCookieFile => cookieMode == UrlImportCookieMode.customFile;

  bool get hasCookieSelection => switch (cookieMode) {
    UrlImportCookieMode.none => false,
    UrlImportCookieMode.customFile => normalizedCookieFilePath != null,
    _ => true,
  };

  int get effectiveParallelDownloads =>
      parallelDownloads < 1 ? 1 : parallelDownloads;

  List<String> inferCookieSites(String sourceUrl) {
    final sites = <String>[];
    final seen = <String>{};

    void addSite(String site) {
      if (seen.add(site)) {
        sites.add(site);
      }
    }

    for (final site in normalizedFavoriteSites) {
      if (site == 'kemono' || site == 'coomer') {
        addSite(site);
      }
    }

    for (final url in collectSourceUrls(sourceUrl)) {
      final lower = url.toLowerCase();
      if (lower.contains('kemono.')) {
        addSite('kemono');
      } else if (lower.contains('coomer.')) {
        addSite('coomer');
      }
    }

    return sites;
  }

  String? resolveProjectCookieProfile(String sourceUrl) {
    switch (cookieMode) {
      case UrlImportCookieMode.none:
      case UrlImportCookieMode.customFile:
        return null;
      case UrlImportCookieMode.projectKemono:
        return 'kemono';
      case UrlImportCookieMode.projectCoomer:
        return 'coomer';
      case UrlImportCookieMode.projectCombined:
        return 'combined';
      case UrlImportCookieMode.auto:
        final sites = inferCookieSites(sourceUrl);
        final hasKemono = sites.contains('kemono');
        final hasCoomer = sites.contains('coomer');
        if (hasKemono && hasCoomer) {
          return 'combined';
        }
        if (hasKemono) {
          return 'kemono';
        }
        if (hasCoomer) {
          return 'coomer';
        }
        return null;
    }
  }

  bool hasAnySource(String sourceUrl) {
    return collectSourceUrls(sourceUrl).isNotEmpty ||
        normalizedUrlListFilePath != null ||
        hasFavoriteTargets;
  }
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
  final String? statusLabel;

  const MediaTransferProgress({
    required this.sentBytes,
    required this.totalBytes,
    required this.completedFiles,
    required this.totalFiles,
    this.currentFileName,
    this.statusLabel,
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
  bool get canImportFromUrl => false;

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

  Future<UrlImportResult> importFromUrlIntoFolder(
    FolderHandle folder,
    String sourceUrl, {
    ImportMetadata? importMetadata,
    UrlImportOptions? options,
    void Function(MediaTransferProgress progress)? onProgress,
  }) async {
    throw UnsupportedError('URL import is not supported in this repository');
  }

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






