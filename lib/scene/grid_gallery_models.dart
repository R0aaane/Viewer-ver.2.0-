// ignore_for_file: file_names, invalid_use_of_protected_member

part of 'gridGallery.dart';

enum _SortMode {
  name,
  updatedAt,
  addedAt,
  unreadFirst,
  readFirst,
  bookmarkedFirst,
}

enum _MainPage { home, gallery, search, hitomiSearch }

enum _HomeMenuAction {
  addFolder,
  importToLibrary,
  importUrlToLibrary,
  artistTagIndex,
  tagManagement,
  metadataSettings,
  refreshFavorites,
  openSearchGallery,
}

enum _GalleryMenuAction {
  addFolder,
  addFile,
  importUrl,
  exportPdf,
  organizeLibrary,
  tagManagement,
  folderTileMode,
  metadataSettings,
  goHome,
}

enum FolderTileMode { labelOnly, preview }

class _PrefsKeys {
  static const String lastFolderRaw = 'prefs.lastFolderRaw';

  static const String folders = 'prefs.folders';
  static const String currentFolder = 'prefs.currentFolder';
  static const String fitMode = 'prefs.readerFitMode';
  static const String twoPage = 'prefs.readerTwoPage';

  static const String favorites = 'prefs.favorites';
  static const String ratingsJson = 'prefs.ratingsJson.v1';

  static const String folderAliasesJson = 'prefs.folderAliasesJson';
  static const String folderTileMode = 'prefs.folderTileMode';
  static const String detailedBrowseCardColumns =
      'prefs.detailedBrowseCardColumns';
  static const String sidebarCollapsed = 'prefs.sidebarCollapsed';
}

class _FolderNavState {
  final FolderHandle folder;
  final int pageIndex;
  const _FolderNavState(this.folder, this.pageIndex);
}

class _HomeResumeCardData {
  final MediaItem item;
  final ReadingProgressEntry progress;

  const _HomeResumeCardData({required this.item, required this.progress});
}

class _GallerySearchSuggestion {
  final String query;
  final String label;
  final String? detail;
  final IconData icon;

  const _GallerySearchSuggestion({
    required this.query,
    required this.label,
    required this.icon,
    this.detail,
  });
}

class _FolderSeriesFilterChip {
  final String name;
  final int count;

  const _FolderSeriesFilterChip({required this.name, required this.count});
}

class _GeneratedPdfPostProcessResult {
  final MediaItem? item;
  final List<Tag> inferredTags;
  final String? relativePathHint;
  final String? tagErrorMessage;
  final String? organizeErrorMessage;
  final String? organizedPath;

  const _GeneratedPdfPostProcessResult({
    this.item,
    this.inferredTags = const <Tag>[],
    this.relativePathHint,
    this.tagErrorMessage,
    this.organizeErrorMessage,
    this.organizedPath,
  });

  bool get hasTagFailure => tagErrorMessage != null;
  bool get hasOrganizeFailure => organizeErrorMessage != null;
  bool get organized => organizedPath != null;
}

enum _UrlImportQueueStatus {
  queued,
  running,
  waiting,
  completed,
  empty,
  failed,
}

enum _SharedUrlImportTargetKind { currentFolder, library }

enum _RegisteredFolderRemovalAction { unregisterOnly, deleteFiles }

enum _ThumbTileMenuAction { renameItem, deleteItem }

enum _AndroidImportConversionChoice { keepImages, mergeToPdf }

class _UrlImportQueueEntry {
  final String id;
  final String title;
  final String folderLabel;
  final _UrlImportQueueStatus status;
  final MediaTransferProgress? progress;
  final String? message;
  final DateTime startedAt;
  final DateTime? finishedAt;

  const _UrlImportQueueEntry({
    required this.id,
    required this.title,
    required this.folderLabel,
    required this.status,
    required this.startedAt,
    this.progress,
    this.message,
    this.finishedAt,
  });

  _UrlImportQueueEntry copyWith({
    _UrlImportQueueStatus? status,
    MediaTransferProgress? progress,
    bool clearProgress = false,
    String? message,
    bool clearMessage = false,
    DateTime? finishedAt,
  }) {
    return _UrlImportQueueEntry(
      id: id,
      title: title,
      folderLabel: folderLabel,
      status: status ?? this.status,
      startedAt: startedAt,
      progress: clearProgress ? null : (progress ?? this.progress),
      message: clearMessage ? null : (message ?? this.message),
      finishedAt: finishedAt ?? this.finishedAt,
    );
  }
}

class _PendingSharedImport {
  final List<String> urls;
  final List<MediaItem> mediaItems;

  const _PendingSharedImport({
    this.urls = const <String>[],
    this.mediaItems = const <MediaItem>[],
  });

  bool get hasUrls => urls.isNotEmpty;
  bool get hasMediaItems => mediaItems.isNotEmpty;
}

class _SharedUrlImportTarget {
  final _SharedUrlImportTargetKind kind;
  final FolderHandle folder;
  final bool activateFolder;
  final String folderLabel;

  const _SharedUrlImportTarget({
    required this.kind,
    required this.folder,
    required this.activateFolder,
    required this.folderLabel,
  });
}
