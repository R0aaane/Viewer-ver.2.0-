import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, Platform;
import 'dart:typed_data';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../database/tag_service.dart';
import '../models/folder.dart';
import '../models/mediaItem.dart';
import '../models/reading_progress.dart';
import '../models/tag.dart';
import '../database/pdf_export_service.dart';
import '../services/app_reading_progress_service.dart';
import '../services/app_version_service.dart';
import '../services/host_api_server_service.dart';
import '../services/import_tag_rule_service.dart';
import '../services/import_pdf_conversion_service.dart';
import '../services/item_name_service.dart';
import '../services/media_id_resolver.dart';
import '../services/reading_progress_service.dart';
import '../services/controller_navigation_service.dart';
import '../services/external_share_service.dart';
import 'import_to_host_dialog.dart';
import 'tag_assign_after_import.dart';

import '../repository/mediaRepository.dart';
import '../widgets/controller_focusable.dart';

import 'artistTagIndex.dart';
import 'detailImage.dart';
import 'metadata_settings_dialog.dart';
import 'rename_item_dialog.dart';
import 'TagResults.dart';
import 'tag_management_page.dart';
import 'url_import_dialog.dart';

enum _SortMode { name, updatedAt, addedAt }

enum _MainPage { home, gallery, search }

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

  static const String folderAliasesJson = 'prefs.folderAliasesJson';
  static const String folderTileMode = 'prefs.folderTileMode';
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

class GalleryGridPage extends StatefulWidget {
  final MediaRepository repo;
  final TagService tagService;
  final HostApiServerService hostServerService;

  const GalleryGridPage({
    super.key,
    required this.repo,
    required this.tagService,
    required this.hostServerService,
  });

  @override
  State<GalleryGridPage> createState() => _GalleryGridPageState();
}

class _GalleryGridPageState extends State<GalleryGridPage> {
  final ExternalShareService _externalShareService = ExternalShareService();
  final AppVersionService _appVersionService = AppVersionService();
  final MediaIdResolver _homeMediaIdResolver = MediaIdResolver();
  final AppReadingProgressService _readingProgressService =
      AppReadingProgressService();
  FolderHandle? _folder;
  List<MediaItem> _items = const [];
  bool _loading = false;
  bool _initializing = true;
  bool _rescanning = false;
  String? _initializationErrorMessage;
  String? _galleryLoadErrorMessage;
  String? _homeSearchErrorMessage;
  final List<_UrlImportQueueEntry> _urlImportQueue = <_UrlImportQueueEntry>[];
  bool _showUrlImportQueue = true;

  int _loadProcessed = 0;
  int _loadTotal = 0;
  bool _thumbsEnabled = true;

  Timer? _thumbResumeDebounce;
  StreamSubscription<ExternalSharePayload>? _externalShareSubscription;
  final List<_PendingSharedImport> _pendingSharedImports =
      <_PendingSharedImport>[];
  final Set<String> _handledSharedPayloadKeys = <String>{};
  final Set<String> _shownVersionMismatchKeys = <String>{};
  bool _processingSharedImport = false;

  final LinkedHashMap<String, Uint8List?> _folderPreviewCache = LinkedHashMap();
  int _folderPreviewCacheBytes = 0;
  static const int _folderPreviewCacheMaxEntries = 120;
  static const int _folderPreviewCacheMaxBytes = 24 * 1024 * 1024; // 24MB

  final Map<String, Future<Uint8List?>> _folderPreviewInFlight = {};

  int _folderPreviewActive = 0;
  final List<Completer<void>> _folderPreviewWaiters = [];

  Future<void> _acquireFolderPreviewSlot([int max = 1]) async {
    if (_folderPreviewActive < max) {
      _folderPreviewActive++;
      return;
    }
    final c = Completer<void>();
    _folderPreviewWaiters.add(c);
    await c.future;
    _folderPreviewActive++;
  }

  void _releaseFolderPreviewSlot() {
    _folderPreviewActive--;
    if (_folderPreviewWaiters.isNotEmpty) {
      _folderPreviewWaiters.removeAt(0).complete();
    }
  }

  Uint8List? _folderPreviewCacheGet(String key) {
    final v = _folderPreviewCache.remove(key);
    if (v == null && !_folderPreviewCache.containsKey(key)) return null;
    _folderPreviewCache[key] = v;
    return v;
  }

  void _folderPreviewCachePut(String key, Uint8List? bytes) {
    final old = _folderPreviewCache.remove(key);
    if (old != null) _folderPreviewCacheBytes -= old.lengthInBytes;

    _folderPreviewCache[key] = bytes;
    if (bytes != null) _folderPreviewCacheBytes += bytes.lengthInBytes;

    while (_folderPreviewCache.isNotEmpty &&
        (_folderPreviewCache.length > _folderPreviewCacheMaxEntries ||
            _folderPreviewCacheBytes > _folderPreviewCacheMaxBytes)) {
      final oldestKey = _folderPreviewCache.keys.first;
      final oldestVal = _folderPreviewCache.remove(oldestKey);
      if (oldestVal != null) {
        _folderPreviewCacheBytes -= oldestVal.lengthInBytes;
      }
    }
  }

  static const int _pageSize = 20;
  int _galleryPageIndex = 0;
  int _galleryTotal = 0;

  FolderTileMode _folderTileMode = FolderTileMode.labelOnly;

  String _parentDirOfFullPath(String fullPath) {
    final p = fullPath.replaceAll('/', '\\');
    final idx = p.lastIndexOf('\\');
    if (idx <= 0) return p;
    return p.substring(0, idx);
  }

  Set<String> _favorites = <String>{};

  // tags（タグID付き）
  Map<String, List<String>> _tagsById = <String, List<String>>{};
  Map<String, List<TagWithId>> _tagDetailsById = <String, List<TagWithId>>{};
  bool _currentPageMetadataAvailable = true;

  _MainPage _page = _MainPage.home;

  List<String> _foldersRaw = const [];
  String? _currentFolderRaw;

  ReaderFitMode _fitMode = ReaderFitMode.vertical;
  bool _twoPage = false;

  final TextEditingController _homeSearchCtrl = TextEditingController();
  String _homeQuery = '';
  bool _homeSearching = false;
  List<MediaItem> _homeSearchResults = const [];
  List<MediaItem> _homeSearchCorpus = const [];
  Map<String, List<TagWithId>> _dbTagDetailsByItemId =
      <String, List<TagWithId>>{};
  String _homeSearchCorpusSignature = '';
  _SortMode _homeSearchSortMode = _SortMode.updatedAt;
  int _homeSearchPageIndex = 0;

  Timer? _homeSearchDebounce;

  Map<String, List<String>> _dbTagsByItemId = <String, List<String>>{};

  final List<_FolderNavState> _dirStack = <_FolderNavState>[];

  bool get _canGoUp => _dirStack.isNotEmpty;

  Future<void> _enterFolder(MediaItem folderItem) async {
    if (_folder == null) return;

    _dirStack.add(_FolderNavState(_folder!, _galleryPageIndex));

    await _loadFolder(
      FolderHandle(folderItem.id),
      saveAsLast: false,
      pageIndex: 0,
    );
  }

  Future<void> _goUpFolder() async {
    if (_dirStack.isEmpty) return;
    final prev = _dirStack.removeLast();

    await _loadFolder(
      prev.folder,
      saveAsLast: false,
      pageIndex: prev.pageIndex,
    );
  }

  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  String _query = '';
  bool _gallerySearchSuggestionsEnabled = false;
  List<MediaItem>? _gallerySearchItemsAll;
  String? _gallerySearchFolderRaw;
  bool _gallerySearchLoading = false;
  bool _gallerySearchLoadingTags = false;
  int _gallerySearchLoadVersion = 0;
  Map<String, List<String>> _gallerySearchTagsById = <String, List<String>>{};
  Map<String, List<TagWithId>> _gallerySearchTagDetailsById =
      <String, List<TagWithId>>{};

  _SortMode _sortMode = _SortMode.name;

  Map<String, String> _folderAliases = <String, String>{};

  final Map<String, List<MediaItem>> _folderItemsCache = {};
  List<MediaItem> _favoriteItemsAll = const [];
  Set<String> _favoriteResolvedIds = <String>{};
  bool _loadingFavAll = false;
  bool _homeShowcaseLoading = false;
  String? _homeShowcaseErrorMessage;
  List<MediaItem> _homeRecentAddedItems = const [];
  List<MediaItem> _homeUnreadItems = const [];
  List<MediaItem> _homeFavoriteShowcaseItems = const [];
  List<MediaItem> _homeRecentViewedItems = const [];
  Map<String, ReadingProgressEntry> _homeRecentViewEntriesByItemId =
      <String, ReadingProgressEntry>{};
  _HomeResumeCardData? _homeResumeCard;
  int _homeShowcaseLoadVersion = 0;

  final Map<String, List<MediaItem>> _folderItemsCacheRecursive = {};

  bool _selectMode = false;
  final Set<String> _selectedIds = <String>{};

  RepositoryCapabilities get _repoCapabilities => widget.repo.capabilities;
  bool get _showsRemoteImportAction =>
      _repoCapabilities.canImportToHost && !_repoCapabilities.canAddLocalFolder;
  String get _primaryAddActionLabel =>
      _showsRemoteImportAction ? 'ホストへ取り込み' : 'フォルダ追加';
  String get _galleryAddFileLabel =>
      _showsRemoteImportAction ? 'ホストへ取り込み' : 'ファイル追加';
  IconData get _primaryAddActionIcon => _showsRemoteImportAction
      ? Icons.cloud_upload_outlined
      : Icons.create_new_folder_outlined;

  void _exitSelectMode() {
    setState(() {
      _selectMode = false;
      _selectedIds.clear();
    });
  }

  void _toggleSelect(MediaItem item) {
    setState(() {
      if (_selectedIds.contains(item.id)) {
        _selectedIds.remove(item.id);
        if (_selectedIds.isEmpty) _selectMode = false;
      } else {
        _selectedIds.add(item.id);
        _selectMode = true;
      }
    });
  }

  void _enterSelectMode(MediaItem item) {
    setState(() {
      _selectMode = true;
      _selectedIds.add(item.id);
    });
  }

  void _selectAll(List<MediaItem> view) {
    setState(() {
      _selectMode = true;
      _selectedIds
        ..clear()
        ..addAll(view.map((e) => e.id));
    });
  }

  void _clearSelection() {
    setState(() {
      _selectedIds.clear();
      _selectMode = false;
    });
  }

  List<MediaItem> _selectedFrom(List<MediaItem> view) {
    if (_selectedIds.isEmpty) return const [];
    return view
        .where((e) => _selectedIds.contains(e.id))
        .toList(growable: false);
  }

  bool _tabListenerInstalled = false;

  Set<String> _idVariants(String id) {
    final s = <String>{id};

    s.add(id.replaceAll('/', '\\'));
    s.add(id.replaceAll('\\', '/'));

    final lower = id.toLowerCase();
    s.add(lower);
    s.add(lower.replaceAll('/', '\\'));
    s.add(lower.replaceAll('\\', '/'));

    return s;
  }

  bool _looksLikeStableMediaId(String value) {
    return value.trim().startsWith('mid_');
  }

  String _readingProgressLookupKey(String folderRaw, String title) {
    final normalizedTitle = title.trim().toLowerCase();
    final normalizedFolder = folderRaw.trim();
    if (normalizedTitle.isEmpty || normalizedFolder.isEmpty) {
      return '';
    }
    final folderKey = normalizedFolder.startsWith('content://')
        ? normalizedFolder
        : _normalizePath(normalizedFolder);
    return '$folderKey|$normalizedTitle';
  }

  Future<Map<String, MediaItem>> _buildHomeItemLookup(
    List<MediaItem> mediaItems,
    Iterable<ReadingProgressEntry> recentProgress,
  ) async {
    final itemByVariant = <String, MediaItem>{};
    for (final item in mediaItems) {
      for (final variant in _idVariants(item.id)) {
        itemByVariant.putIfAbsent(variant, () => item);
      }
      final progressLookupKey = _readingProgressLookupKey(
        item.folderRaw,
        item.displayName,
      );
      if (progressLookupKey.isNotEmpty) {
        itemByVariant.putIfAbsent(progressLookupKey, () => item);
      }
    }

    final unresolvedStableIds = recentProgress
        .map((entry) => entry.mediaId.trim())
        .where(_looksLikeStableMediaId)
        .where((itemId) => !itemByVariant.containsKey(itemId))
        .toSet();
    if (unresolvedStableIds.isEmpty) {
      return itemByVariant;
    }

    for (final item in mediaItems) {
      try {
        final stableId = (await _homeMediaIdResolver.resolve(item)).stableId;
        itemByVariant.putIfAbsent(stableId, () => item);
        unresolvedStableIds.remove(stableId);
        if (unresolvedStableIds.isEmpty) {
          break;
        }
      } catch (_) {
        continue;
      }
    }

    return itemByVariant;
  }

  bool _loadingArtistTags = false;
  List<TagWithId> _artistTagMasters = const [];
  Map<String, int> _tagCountCache = const {};

  Future<void> _reloadArtistTagMasters() async {
    setState(() => _loadingArtistTags = true);
    try {
      final list = await widget.tagService.listTagMasterByCategory(
        TagCategory.artist,
      );
      if (!mounted) return;
      setState(() => _artistTagMasters = list);
      unawaited(_refreshArtistTagCounts());
    } finally {
      if (mounted) setState(() => _loadingArtistTags = false);
    }
  }

  Future<void> _refreshArtistTagCounts() async {
    final all = <MediaItem>[];
    for (final raw in _foldersRaw) {
      if (!_folderItemsCacheRecursive.containsKey(raw)) {
        try {
          _folderItemsCacheRecursive[raw] = await widget.repo
              .listMediaRecursiveFiles(FolderHandle(raw));
        } catch (_) {
          _folderItemsCacheRecursive[raw] = const <MediaItem>[];
        }
      }

      all.addAll(
        (_folderItemsCacheRecursive[raw] ?? const <MediaItem>[]).where(
          (item) => item.kind != MediaKind.folder,
        ),
      );
    }

    final details = await widget.tagService.getDetailedTagsByItems(all);
    final counts = <String, int>{};
    for (final tags in details.values) {
      for (final tag in tags) {
        if (tag.tag.category != TagCategory.artist) continue;
        final key = tag.tag.name.toLowerCase();
        counts[key] = (counts[key] ?? 0) + 1;
      }
    }

    if (!mounted) return;
    setState(() => _tagCountCache = counts);
  }

  Future<void> _openTagGalleryFromDrawer(String tagName) async {
    _closeSidebar();
    _exitSelectMode();
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TagResultsPage(
          tagService: widget.tagService,
          repo: widget.repo,
          folderRaws: _foldersRaw,
          category: TagCategory.artist,
          tagName: tagName,
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _searchFocusNode.addListener(_handleGallerySearchFocusChange);
    _loadPrefsAndAutoOpenFolder();
    unawaited(_initializeHostServerAndCheckVersion());
    _bindExternalSharePayloads();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reloadArtistTagMasters();
    });
  }

  void _bindExternalSharePayloads() {
    _externalShareSubscription = _externalShareService.payloads.listen((
      payload,
    ) {
      unawaited(_queueSharedImportPayload(payload));
    });
    unawaited(() async {
      final payload = await _externalShareService.takeInitialPayload();
      if (payload == null) {
        return;
      }
      await _queueSharedImportPayload(payload);
    }());
  }

  Future<void> _queueSharedImportPayload(ExternalSharePayload payload) async {
    final mediaItems = await _extractSharedImportMediaItems(payload);
    final urls = mediaItems.isEmpty
        ? _extractSharedImportUrls(payload)
        : const <String>[];
    if (mediaItems.isEmpty && urls.isEmpty) {
      return;
    }

    final payloadKey = mediaItems.isNotEmpty
        ? '${payload.action}|${payload.mimeType}|media|${mediaItems.map((item) => item.id).join('\n')}'
        : '${payload.action}|${payload.mimeType}|url|${urls.join('\n')}';
    if (!_handledSharedPayloadKeys.add(payloadKey)) {
      return;
    }

    _pendingSharedImports.add(
      _PendingSharedImport(urls: urls, mediaItems: mediaItems),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(_drainSharedImportQueue());
    });
  }

  Future<List<MediaItem>> _extractSharedImportMediaItems(
    ExternalSharePayload payload,
  ) async {
    try {
      final resolved = await widget.repo.resolveExternalItems(payload.rawItems);
      final mediaItems = <MediaItem>[];
      final seen = <String>{};
      for (final item in resolved) {
        if (item.kind == MediaKind.folder) {
          continue;
        }
        if (seen.add(item.id)) {
          mediaItems.add(item);
        }
      }
      return mediaItems;
    } catch (error, stackTrace) {
      _logUiError('shared-import-resolve', error, stackTrace);
      return const <MediaItem>[];
    }
  }

  List<String> _extractSharedImportUrls(ExternalSharePayload payload) {
    final urls = <String>[];
    final seen = <String>{};
    for (final rawItem in payload.rawItems) {
      for (final url in const UrlImportOptions().collectSourceUrls(rawItem)) {
        if (!_isSupportedSharedImportUrl(url)) {
          continue;
        }
        if (seen.add(url)) {
          urls.add(url);
        }
      }
    }
    return urls;
  }

  bool _isSupportedSharedImportUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null) {
      return false;
    }
    final scheme = uri.scheme.trim().toLowerCase();
    return (scheme == 'http' || scheme == 'https') &&
        uri.host.trim().isNotEmpty;
  }

  Future<void> _drainSharedImportQueue() async {
    if (_processingSharedImport || _initializing || !mounted) {
      return;
    }
    _processingSharedImport = true;
    try {
      while (mounted && !_initializing && _pendingSharedImports.isNotEmpty) {
        final pending = _pendingSharedImports.removeAt(0);
        await _handlePendingSharedImport(pending);
      }
    } finally {
      _processingSharedImport = false;
      if (mounted && !_initializing && _pendingSharedImports.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) {
            return;
          }
          unawaited(_drainSharedImportQueue());
        });
      }
    }
  }

  void _handleGallerySearchFocusChange() {
    if (_searchFocusNode.hasFocus) {
      if (!_gallerySearchSuggestionsEnabled && mounted) {
        setState(() => _gallerySearchSuggestionsEnabled = true);
      }
      unawaited(_ensureGallerySearchCacheLoaded());
      return;
    }
    if (!mounted) return;
    if (_gallerySearchSuggestionsEnabled) {
      setState(() => _gallerySearchSuggestionsEnabled = false);
    }
  }

  Future<void> _initializeHostServerAndCheckVersion() async {
    await widget.hostServerService.refresh();
    final settings = widget.tagService.settings;
    if (settings.isHostMode && settings.autoStartHostServer) {
      try {
        await widget.hostServerService.startServer(
          tagService: widget.tagService,
        );
      } catch (error, stackTrace) {
        _logUiError('initializeHostServerIfNeeded', error, stackTrace);
      }
    }
    await _checkAppVersionCompatibility();
  }

  Future<void> _checkAppVersionCompatibility() async {
    try {
      final mismatch = await _appVersionService.findHostVersionMismatch(
        widget.tagService.settings,
      );
      if (mismatch == null || !mounted) {
        return;
      }

      final mismatchKey =
          '${mismatch.hostUrl}|${mismatch.localVersion}|${mismatch.hostVersion}';
      if (!_shownVersionMismatchKeys.add(mismatchKey)) {
        return;
      }

      final olderTargets = <String>[
        if (mismatch.isLocalOlder) 'この端末',
        if (mismatch.isHostOlder) 'ホスト側',
      ];
      final olderTarget = olderTargets.isEmpty
          ? '古い側のアプリ'
          : '${olderTargets.join('と')}のアプリ';
      final openUpdate = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: const Text('アプリのバージョンが違います'),
            content: Text(
              'この端末: ${mismatch.localVersion}\n'
              'ホスト: ${mismatch.hostVersion}\n'
              '最新: ${mismatch.latestVersion}\n\n'
              '不具合防止のため、$olderTargetをアップデートしてから利用してください。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('後で'),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(mismatch.hasUpdateUrl),
                child: Text(mismatch.hasUpdateUrl ? 'アップデート' : '確認'),
              ),
            ],
          );
        },
      );
      if (openUpdate == true) {
        final opened = await _appVersionService.openUpdate(mismatch);
        if (!opened && mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('更新先を開けませんでした')));
        }
      }
    } catch (error, stackTrace) {
      _logUiError('checkAppVersionCompatibility', error, stackTrace);
    }
  }

  void _logUiError(String label, Object error, StackTrace stackTrace) {
    debugPrint('[GalleryGridPage][$label] $error');
    debugPrintStack(label: '[GalleryGridPage][$label]', stackTrace: stackTrace);
  }

  bool get _isGallerySearchActive => _query.trim().isNotEmpty;
  bool get _isGallerySearchBusy =>
      _gallerySearchLoading || _gallerySearchLoadingTags;

  void _invalidateGallerySearchCache() {
    _gallerySearchLoadVersion++;
    _gallerySearchFolderRaw = null;
    _gallerySearchItemsAll = null;
    _gallerySearchLoading = false;
    _gallerySearchLoadingTags = false;
    _gallerySearchTagsById = <String, List<String>>{};
    _gallerySearchTagDetailsById = <String, List<TagWithId>>{};
  }

  Future<void> _ensureGallerySearchCacheLoaded() async {
    final folder = _folder;
    if (folder == null) return;

    final folderRaw = folder.raw;
    if (_gallerySearchFolderRaw == folderRaw &&
        _gallerySearchItemsAll != null &&
        !_gallerySearchLoading &&
        !_gallerySearchLoadingTags) {
      return;
    }

    if ((_gallerySearchLoading || _gallerySearchLoadingTags) &&
        _gallerySearchFolderRaw == folderRaw) {
      return;
    }

    final loadVersion = ++_gallerySearchLoadVersion;
    if (mounted) {
      setState(() {
        _gallerySearchFolderRaw = folderRaw;
        _gallerySearchLoading = true;
        _gallerySearchLoadingTags = false;
        _gallerySearchItemsAll = null;
        _gallerySearchTagsById = <String, List<String>>{};
        _gallerySearchTagDetailsById = <String, List<TagWithId>>{};
      });
    }

    try {
      final useCurrentPage =
          _galleryTotal > 0 &&
          _galleryTotal <= _items.length &&
          _items.every((item) => item.folderRaw == folderRaw);
      final allItems = useCurrentPage
          ? _items
          : await widget.repo.listMedia(folder);

      if (!mounted ||
          _gallerySearchLoadVersion != loadVersion ||
          _folder?.raw != folderRaw) {
        return;
      }

      widget.tagService.rememberItems(allItems);

      setState(() {
        _gallerySearchItemsAll = allItems.toList(growable: false);
        _gallerySearchLoading = false;
        _gallerySearchLoadingTags = true;
      });

      final nonFolderItems = allItems
          .where((item) => item.kind != MediaKind.folder)
          .toList(growable: false);
      final details = nonFolderItems.isEmpty
          ? const <String, List<TagWithId>>{}
          : await widget.tagService.getDetailedTagsByItems(nonFolderItems);

      if (!mounted ||
          _gallerySearchLoadVersion != loadVersion ||
          _folder?.raw != folderRaw) {
        return;
      }

      setState(() {
        _gallerySearchLoading = false;
        _gallerySearchLoadingTags = false;
        _gallerySearchTagDetailsById = details;
        _gallerySearchTagsById = details.map(
          (key, value) => MapEntry(
            key,
            value.map((entry) => entry.tag.name).toList(growable: false),
          ),
        );
      });
    } catch (error, stackTrace) {
      _logUiError('gallery-search-cache', error, stackTrace);
      if (!mounted ||
          _gallerySearchLoadVersion != loadVersion ||
          _folder?.raw != folderRaw) {
        return;
      }
      setState(() {
        _gallerySearchLoading = false;
        _gallerySearchLoadingTags = false;
      });
    }
  }

  List<MediaItem> _gallerySearchCorpusItems() {
    final folderRaw = _folder?.raw;
    if (folderRaw != null &&
        _gallerySearchFolderRaw == folderRaw &&
        _gallerySearchItemsAll != null) {
      return _gallerySearchItemsAll!;
    }
    return _items;
  }

  List<MediaItem> _gallerySearchBaseItems() {
    if (!_isGallerySearchActive) return _items;
    return _gallerySearchCorpusItems();
  }

  List<String> _searchableTagsFor(MediaItem item) {
    return _gallerySearchTagsById[item.id] ??
        _tagsById[item.id] ??
        const <String>[];
  }

  List<TagWithId> _searchableTagDetailsFor(MediaItem item) {
    return _gallerySearchTagDetailsById[item.id] ??
        _tagDetailsById[item.id] ??
        const <TagWithId>[];
  }

  TagCategory? _tagCategoryForSearchKey(String key) {
    switch (key) {
      case 'artist':
        return TagCategory.artist;
      case 'series':
        return TagCategory.series;
      case 'type':
        return TagCategory.mediaType;
      case 'character':
        return TagCategory.character;
      case 'free':
        return TagCategory.free;
    }
    return null;
  }

  String _tagCategoryLabel(TagCategory category) {
    switch (category) {
      case TagCategory.artist:
        return '作家';
      case TagCategory.series:
        return 'シリーズ';
      case TagCategory.mediaType:
        return '種別';
      case TagCategory.character:
        return 'キャラクター';
      case TagCategory.free:
        return '自由タグ';
    }
  }

  String _mediaKindLabel(MediaKind kind) {
    switch (kind) {
      case MediaKind.folder:
        return 'フォルダ';
      case MediaKind.image:
        return '画像';
      case MediaKind.pdf:
        return 'PDF';
    }
  }

  IconData _mediaKindIcon(MediaKind kind) {
    switch (kind) {
      case MediaKind.folder:
        return Icons.folder_open_outlined;
      case MediaKind.image:
        return Icons.image_outlined;
      case MediaKind.pdf:
        return Icons.picture_as_pdf_outlined;
    }
  }

  String _replaceActiveGallerySearchToken(String rawQuery, String replacement) {
    final trimmedRight = rawQuery.trimRight();
    if (trimmedRight.isEmpty) {
      return replacement;
    }

    if (RegExp(r'\s$').hasMatch(rawQuery)) {
      return '$trimmedRight $replacement';
    }

    final tokenMatch = RegExp(r'\S+$').firstMatch(trimmedRight);
    if (tokenMatch == null) {
      return replacement;
    }

    final prefix = trimmedRight.substring(0, tokenMatch.start).trimRight();
    return prefix.isEmpty ? replacement : '$prefix $replacement';
  }

  String? _activeGallerySeriesFilterKey() {
    final tokens = _query
        .trim()
        .split(RegExp(r'\s+'))
        .where((token) => token.isNotEmpty);

    String? active;
    for (final token in tokens) {
      final separator = token.indexOf(':');
      if (separator <= 0 || separator >= token.length - 1) {
        continue;
      }
      final key = token.substring(0, separator).toLowerCase();
      if (key != 'series') {
        continue;
      }
      final value = token.substring(separator + 1).trim();
      if (value.isEmpty) {
        continue;
      }
      active = value.toLowerCase();
    }
    return active;
  }

  List<_FolderSeriesFilterChip> _currentFolderSeriesFilterChips() {
    final folderRaw = _folder?.raw;
    if (folderRaw == null) {
      return const <_FolderSeriesFilterChip>[];
    }

    final useSearchCache =
        _gallerySearchFolderRaw == folderRaw && _gallerySearchItemsAll != null;
    final items = useSearchCache ? _gallerySearchItemsAll! : _items;
    final tagDetailsById = useSearchCache
        ? _gallerySearchTagDetailsById
        : _tagDetailsById;

    final counts = <String, int>{};
    final labels = <String, String>{};

    for (final item in items) {
      if (item.kind != MediaKind.pdf) {
        continue;
      }
      final details = tagDetailsById[item.id] ?? const <TagWithId>[];
      final seenSeriesInItem = <String>{};
      for (final detail in details) {
        if (detail.tag.category != TagCategory.series) {
          continue;
        }
        final name = detail.tag.name.trim();
        if (name.isEmpty) {
          continue;
        }
        final key = name.toLowerCase();
        if (!seenSeriesInItem.add(key)) {
          continue;
        }
        labels.putIfAbsent(key, () => name);
        counts.update(key, (value) => value + 1, ifAbsent: () => 1);
      }
    }

    final chips = counts.entries
        .map(
          (entry) => _FolderSeriesFilterChip(
            name: labels[entry.key] ?? entry.key,
            count: entry.value,
          ),
        )
        .toList(growable: true);
    chips.sort((left, right) {
      final countCompare = right.count.compareTo(left.count);
      if (countCompare != 0) {
        return countCompare;
      }
      return left.name.toLowerCase().compareTo(right.name.toLowerCase());
    });
    return chips.toList(growable: false);
  }

  void _setGallerySearchQuery(
    String value, {
    required bool enableSuggestions,
    bool syncController = false,
  }) {
    if (!mounted) {
      return;
    }

    setState(() {
      _query = value;
      _gallerySearchSuggestionsEnabled =
          enableSuggestions && _searchFocusNode.hasFocus;
    });

    if (syncController && _searchCtrl.text != value) {
      _searchCtrl.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
    }

    if (value.trim().isNotEmpty || _searchFocusNode.hasFocus) {
      unawaited(_ensureGallerySearchCacheLoaded());
    }
  }

  void _toggleGallerySeriesFilter(String seriesName) {
    final trimmed = seriesName.trim();
    if (trimmed.isEmpty) {
      return;
    }

    final normalizedSeries = trimmed.toLowerCase();
    final tokens = _query
        .trim()
        .split(RegExp(r'\s+'))
        .where((token) => token.isNotEmpty)
        .toList(growable: false);

    final nextTokens = <String>[];
    String? currentSeries;
    for (final token in tokens) {
      final separator = token.indexOf(':');
      if (separator > 0 && separator < token.length - 1) {
        final key = token.substring(0, separator).toLowerCase();
        if (key == 'series') {
          currentSeries = token.substring(separator + 1).trim().toLowerCase();
          continue;
        }
      }
      nextTokens.add(token);
    }

    if (currentSeries != normalizedSeries) {
      nextTokens.add('series:$trimmed');
    }

    _setGallerySearchQuery(
      nextTokens.join(' '),
      enableSuggestions: false,
      syncController: true,
    );
  }

  Iterable<_GallerySearchSuggestion> _buildGallerySearchSuggestions(
    TextEditingValue value,
  ) {
    if (!_searchFocusNode.hasFocus || !_gallerySearchSuggestionsEnabled) {
      return const <_GallerySearchSuggestion>[];
    }

    final rawQuery = value.text;
    final trimmedRight = rawQuery.trimRight();
    final hasTrailingSpace =
        rawQuery.isNotEmpty && RegExp(r'\s$').hasMatch(rawQuery);
    final tokenMatch = hasTrailingSpace
        ? null
        : RegExp(r'\S+$').firstMatch(trimmedRight);
    final activeToken = tokenMatch?.group(0) ?? '';
    final normalizedToken = activeToken.toLowerCase();

    final suggestions = <_GallerySearchSuggestion>[];
    final seenQueries = <String>{};

    void addSuggestion(_GallerySearchSuggestion suggestion) {
      final key = suggestion.query.toLowerCase();
      if (seenQueries.add(key)) {
        suggestions.add(suggestion);
      }
    }

    void addOperatorSuggestion(
      String replacement,
      String detail,
      IconData icon,
    ) {
      addSuggestion(
        _GallerySearchSuggestion(
          query: _replaceActiveGallerySearchToken(rawQuery, replacement),
          label: replacement,
          detail: detail,
          icon: icon,
        ),
      );
    }

    final operatorHints = <({String token, String detail, IconData icon})>[
      (token: 'artist:', detail: '作家タグで絞り込み', icon: Icons.person_outline),
      (
        token: 'series:',
        detail: 'シリーズタグで絞り込み',
        icon: Icons.collections_bookmark_outlined,
      ),
      (token: 'type:', detail: '種別タグで絞り込み', icon: Icons.category_outlined),
      (
        token: 'character:',
        detail: 'キャラクタータグで絞り込み',
        icon: Icons.badge_outlined,
      ),
      (token: 'free:', detail: '自由タグで絞り込み', icon: Icons.sell_outlined),
    ];

    if (!normalizedToken.startsWith('#')) {
      for (final hint in operatorHints) {
        final compactHint = hint.token.replaceAll(':', '');
        final compactToken = normalizedToken.replaceAll(':', '');
        if (normalizedToken.isEmpty || compactHint.startsWith(compactToken)) {
          addOperatorSuggestion(hint.token, hint.detail, hint.icon);
        }
      }
    }

    if (normalizedToken.isEmpty ||
        'untagged'.contains(normalizedToken) ||
        '未分類'.contains(normalizedToken)) {
      addOperatorSuggestion(
        'untagged',
        'タグが付いていない項目のみ',
        Icons.label_off_outlined,
      );
    }

    final items = _gallerySearchCorpusItems();
    final uniqueNames = <String>{};
    final uniqueTagNames = <String>{};
    final uniqueCategoryTags = <TagCategory, Set<String>>{};

    for (final item in items) {
      uniqueNames.add(item.displayName);
      for (final tagName in _searchableTagsFor(item)) {
        uniqueTagNames.add(tagName);
      }
      for (final detail in _searchableTagDetailsFor(item)) {
        uniqueCategoryTags
            .putIfAbsent(detail.tag.category, () => <String>{})
            .add(detail.tag.name);
      }
    }

    if (normalizedToken.startsWith('#')) {
      final needle = normalizedToken.substring(1);
      for (final tagName in uniqueTagNames) {
        final normalizedTag = tagName.toLowerCase();
        if (needle.isNotEmpty && !normalizedTag.contains(needle)) continue;
        addSuggestion(
          _GallerySearchSuggestion(
            query: _replaceActiveGallerySearchToken(rawQuery, '#$tagName'),
            label: '#$tagName',
            detail: 'タグ',
            icon: Icons.sell_outlined,
          ),
        );
        if (suggestions.length >= 8) break;
      }
      return suggestions.take(8);
    }

    final separator = normalizedToken.indexOf(':');
    if (separator > 0 && separator < normalizedToken.length) {
      final key = normalizedToken.substring(0, separator);
      final valuePart = normalizedToken.substring(separator + 1);
      final category = _tagCategoryForSearchKey(key);
      if (category != null) {
        final names = uniqueCategoryTags[category] ?? <String>{};
        for (final tagName in names) {
          final normalizedTag = tagName.toLowerCase();
          if (valuePart.isNotEmpty && !normalizedTag.contains(valuePart)) {
            continue;
          }
          addSuggestion(
            _GallerySearchSuggestion(
              query: _replaceActiveGallerySearchToken(
                rawQuery,
                '$key:$tagName',
              ),
              label: '$key:$tagName',
              detail: '${_tagCategoryLabel(category)}タグ',
              icon: Icons.sell_outlined,
            ),
          );
          if (suggestions.length >= 8) break;
        }
        return suggestions.take(8);
      }
    }

    if (normalizedToken.isNotEmpty) {
      for (final name in uniqueNames) {
        if (!name.toLowerCase().contains(normalizedToken)) continue;
        MediaItem? matchedItem;
        for (final item in items) {
          if (item.displayName == name) {
            matchedItem = item;
            break;
          }
        }
        addSuggestion(
          _GallerySearchSuggestion(
            query: _replaceActiveGallerySearchToken(rawQuery, name),
            label: name,
            detail: matchedItem == null
                ? null
                : _mediaKindLabel(matchedItem.kind),
            icon: matchedItem == null
                ? Icons.search
                : _mediaKindIcon(matchedItem.kind),
          ),
        );
        if (suggestions.length >= 8) {
          return suggestions.take(8);
        }
      }

      for (final tagName in uniqueTagNames) {
        if (!tagName.toLowerCase().contains(normalizedToken)) continue;
        addSuggestion(
          _GallerySearchSuggestion(
            query: _replaceActiveGallerySearchToken(rawQuery, '#$tagName'),
            label: '#$tagName',
            detail: 'タグ',
            icon: Icons.sell_outlined,
          ),
        );
        if (suggestions.length >= 8) {
          return suggestions.take(8);
        }
      }
    }

    return suggestions.take(8);
  }

  void _handleGallerySearchChanged(
    String value, {
    bool keepSuggestionsVisible = true,
  }) {
    _setGallerySearchQuery(value, enableSuggestions: keepSuggestionsVisible);
  }

  void _clearGallerySearchQuery() {
    _setGallerySearchQuery(
      '',
      enableSuggestions: _searchFocusNode.hasFocus,
      syncController: true,
    );
  }

  Widget? _buildGallerySearchSuffix() {
    if (!_isGallerySearchBusy && !_isGallerySearchActive) {
      return null;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_isGallerySearchBusy)
          const Padding(
            padding: EdgeInsets.only(right: 4),
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        if (_isGallerySearchActive)
          IconButton(
            tooltip: 'クリア',
            icon: const Icon(Icons.clear),
            onPressed: _clearGallerySearchQuery,
          ),
      ],
    );
  }

  Widget _buildGallerySearchField() {
    return RawAutocomplete<_GallerySearchSuggestion>(
      textEditingController: _searchCtrl,
      focusNode: _searchFocusNode,
      displayStringForOption: (option) => option.query,
      optionsBuilder: _buildGallerySearchSuggestions,
      onSelected: (option) => _handleGallerySearchChanged(
        option.query,
        keepSuggestionsVisible: false,
      ),
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        return TextField(
          controller: controller,
          focusNode: focusNode,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: 'タイトル / #タグ / artist:xxx / series:yyy',
            border: const OutlineInputBorder(),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
            suffixIconConstraints: const BoxConstraints(minWidth: 0),
            suffixIcon: _buildGallerySearchSuffix(),
          ),
          onTap: () {
            if (!_gallerySearchSuggestionsEnabled && mounted) {
              setState(() => _gallerySearchSuggestionsEnabled = true);
            }
            unawaited(_ensureGallerySearchCacheLoaded());
          },
          onTapOutside: (_) => focusNode.unfocus(),
          onChanged: (value) =>
              _handleGallerySearchChanged(value, keepSuggestionsVisible: true),
          onSubmitted: (_) {
            _handleGallerySearchChanged(
              controller.text,
              keepSuggestionsVisible: false,
            );
            onFieldSubmitted();
          },
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        final optionList = options.toList(growable: false);
        if (optionList.isEmpty) {
          return const SizedBox.shrink();
        }

        final maxWidth = _isWideLayout(context)
            ? 520.0
            : MediaQuery.sizeOf(context).width - 24;
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              width: maxWidth,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: ListView.builder(
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  itemCount: optionList.length,
                  itemBuilder: (context, index) {
                    final option = optionList[index];
                    return ListTile(
                      dense: true,
                      leading: Icon(option.icon),
                      title: Text(
                        option.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: option.detail == null
                          ? null
                          : Text(option.detail!),
                      onTap: () => onSelected(option),
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildStatusBody({
    required IconData icon,
    required String title,
    String? message,
    Widget? indicator,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  indicator ??
                      Icon(icon, size: 40, color: theme.colorScheme.primary),
                  const SizedBox(height: 16),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium,
                  ),
                  if (message != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      message,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                  if (actionLabel != null && onAction != null) ...[
                    const SizedBox(height: 16),
                    FilledButton(onPressed: onAction, child: Text(actionLabel)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingBody({
    required String title,
    String? message,
    double? progress,
  }) {
    Widget indicator = const SizedBox(
      width: 32,
      height: 32,
      child: CircularProgressIndicator(),
    );
    if (progress != null) {
      indicator = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: 220,
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0).toDouble(),
            ),
          ),
        ],
      );
    }
    return _buildStatusBody(
      icon: Icons.hourglass_top_rounded,
      title: title,
      message: message,
      indicator: indicator,
    );
  }

  Widget _buildErrorBody({
    required String title,
    required String message,
    String actionLabel = '再試行',
    VoidCallback? onAction,
  }) {
    return _buildStatusBody(
      icon: Icons.error_outline,
      title: title,
      message: message,
      actionLabel: onAction == null ? null : actionLabel,
      onAction: onAction,
    );
  }

  Widget _buildEmptyBody({
    required String title,
    required String message,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return _buildStatusBody(
      icon: Icons.inbox_outlined,
      title: title,
      message: message,
      actionLabel: actionLabel,
      onAction: onAction,
    );
  }

  Widget _buildGuardedBody(String label, Widget Function() builder) {
    try {
      return builder();
    } catch (error, stackTrace) {
      _logUiError('build:$label', error, stackTrace);
      return _buildErrorBody(
        title: '画面の描画に失敗しました',
        message: '$label の build 中に例外が発生しました。\n$error',
      );
    }
  }

  ScrollPhysics get _refreshScrollPhysics =>
      const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics());

  Widget _buildRefreshableStatusBody({
    required Future<void> Function() onRefresh,
    required Widget child,
  }) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            physics: _refreshScrollPhysics,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: child,
            ),
          );
        },
      ),
    );
  }

  Future<void> _retryInitialization() async {
    if (_initializing) return;
    await _loadPrefsAndAutoOpenFolder(pageIndex: _galleryPageIndex);
  }

  Future<void> _loadPrefsAndAutoOpenFolder({int pageIndex = 0}) async {
    if (mounted) {
      setState(() {
        _initializing = true;
        _initializationErrorMessage = null;
      });
    } else {
      _initializing = true;
      _initializationErrorMessage = null;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      Map<String, String> aliases = <String, String>{};
      var aliasesUpdated = false;
      final aliasesJson = prefs.getString(_PrefsKeys.folderAliasesJson);
      if (aliasesJson != null && aliasesJson.isNotEmpty) {
        try {
          final decoded = jsonDecode(aliasesJson);
          if (decoded is Map) {
            for (final e in decoded.entries) {
              final k = e.key?.toString();
              final v = e.value?.toString();
              if (k == null || v == null) continue;
              final sanitized = _sanitizeFolderAlias(v, fallbackRaw: k);
              if (sanitized != null) {
                aliases[k] = sanitized;
              }
              if (sanitized != v) {
                aliasesUpdated = true;
              }
            }
          }
        } catch (_) {}
      }
      final favList =
          prefs.getStringList(_PrefsKeys.favorites) ?? const <String>[];
      _tagsById = <String, List<String>>{};
      _tagDetailsById = <String, List<TagWithId>>{};
      final fitIndex = prefs.getInt(_PrefsKeys.fitMode);
      final two = prefs.getBool(_PrefsKeys.twoPage);
      List<String> folders =
          prefs.getStringList(_PrefsKeys.folders) ?? const <String>[];
      String? current = prefs.getString(_PrefsKeys.currentFolder);
      if (folders.isEmpty) {
        final legacy = prefs.getString(_PrefsKeys.lastFolderRaw);
        if (legacy != null && legacy.isNotEmpty) {
          if (Platform.isWindows) {
            folders = <String>[legacy];
            current = legacy;
            await prefs.setStringList(_PrefsKeys.folders, folders);
            await prefs.setString(_PrefsKeys.currentFolder, legacy);
          } else {
            await prefs.remove(_PrefsKeys.lastFolderRaw);
          }
        }
      }
      final modeIndex = prefs.getInt(_PrefsKeys.folderTileMode);
      if (modeIndex != null &&
          modeIndex >= 0 &&
          modeIndex < FolderTileMode.values.length) {
        _folderTileMode = FolderTileMode.values[modeIndex];
      }
      if (widget.repo.isRemoteMode) {
        List<FolderHandle> remoteFolders = const <FolderHandle>[];
        try {
          remoteFolders = await widget.repo.listAvailableFolders();
        } catch (error, stackTrace) {
          _logUiError('remote-folders', error, stackTrace);
          final message = 'ホストに接続できません: $error';
          if (!mounted) return;
          setState(() {
            if (fitIndex != null &&
                fitIndex >= 0 &&
                fitIndex < ReaderFitMode.values.length) {
              _fitMode = ReaderFitMode.values[fitIndex];
            }
            if (two != null) _twoPage = two;
            _favorites = favList.toSet();
            _foldersRaw = const <String>[];
            _currentFolderRaw = null;
            _folderAliases = aliases;
            _items = const [];
            _folder = null;
            _galleryLoadErrorMessage = null;
            _initializationErrorMessage = message;
          });
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
          return;
        }
        final remoteRaws = remoteFolders
            .map((entry) => entry.raw)
            .where((entry) => entry.trim().isNotEmpty)
            .toList(growable: false);
        if (current == null || !remoteRaws.contains(current)) {
          current = remoteRaws.isNotEmpty ? remoteRaws.first : null;
        }
        setState(() {
          if (fitIndex != null &&
              fitIndex >= 0 &&
              fitIndex < ReaderFitMode.values.length) {
            _fitMode = ReaderFitMode.values[fitIndex];
          }
          if (two != null) _twoPage = two;
          _favorites = favList.toSet();
          _foldersRaw = remoteRaws;
          _currentFolderRaw = current;
          _folderAliases = aliases;
          _initializationErrorMessage = null;
          if (current == null) {
            _items = const [];
            _folder = null;
            _galleryLoadErrorMessage = null;
          }
        });
        if (current == null) {
          await _refreshHomeShowcases();
          return;
        }
        await _loadFolder(
          FolderHandle(current),
          saveAsLast: false,
          pageIndex: pageIndex,
        );
        return;
      }
      final lib = await widget.repo.getAppLibraryFolder();
      final libRaw = lib.raw;
      if (!folders.contains(libRaw)) {
        folders = <String>[libRaw, ...folders];
        await prefs.setStringList(_PrefsKeys.folders, folders);
      }
      if (!aliases.containsKey(libRaw) || aliases[libRaw]!.trim().isEmpty) {
        aliases[libRaw] = '保管庫';
        aliasesUpdated = true;
      }
      final existsFolders = <String>{};
      for (final p in folders) {
        if (p.startsWith('content://')) {
          existsFolders.add(p);
          continue;
        }
        try {
          final d = Directory(p);
          if (await d.exists()) existsFolders.add(p);
        } catch (_) {}
      }
      if (current == null || !existsFolders.contains(current)) {
        if (existsFolders.contains(libRaw)) {
          current = libRaw;
        } else {
          current = existsFolders.isNotEmpty ? existsFolders.first : null;
        }
      }
      await prefs.setStringList(_PrefsKeys.folders, existsFolders.toList());
      if (current != null) {
        await prefs.setString(_PrefsKeys.currentFolder, current);
      } else {
        await prefs.remove(_PrefsKeys.currentFolder);
      }
      if (!aliases.containsKey(libRaw) || aliases[libRaw]!.trim().isEmpty) {
        aliases[libRaw] = '保管庫';
        aliasesUpdated = true;
      }
      if (!folders.contains(libRaw)) {
        folders = List<String>.from(folders)..insert(0, libRaw);
        await prefs.setStringList(_PrefsKeys.folders, folders);
      }
      if (aliasesUpdated) {
        await prefs.setString(
          _PrefsKeys.folderAliasesJson,
          jsonEncode(aliases),
        );
      }
      setState(() {
        if (fitIndex != null &&
            fitIndex >= 0 &&
            fitIndex < ReaderFitMode.values.length) {
          _fitMode = ReaderFitMode.values[fitIndex];
        }
        if (two != null) _twoPage = two;
        _favorites = favList.toSet();
        _foldersRaw = existsFolders.toList(growable: false);
        _currentFolderRaw = current;
        _folderAliases = aliases;
        _initializationErrorMessage = null;
      });
      if (current == null) {
        await _refreshHomeShowcases();
        return;
      }
      await _loadFolder(
        FolderHandle(current),
        saveAsLast: false,
        pageIndex: pageIndex,
      );
    } catch (error, stackTrace) {
      _logUiError('init', error, stackTrace);
      final message = 'アプリの初期化に失敗しました: $error';
      if (!mounted) return;
      setState(() {
        _folder = null;
        _items = const [];
        _galleryLoadErrorMessage = null;
        _initializationErrorMessage = message;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) {
        setState(() => _initializing = false);
        unawaited(_drainSharedImportQueue());
      } else {
        _initializing = false;
      }
    }
  }

  Future<void> _refreshVisibleContent({
    bool refreshRegisteredFolders = false,
  }) async {
    _folderItemsCache.clear();
    _folderItemsCacheRecursive.clear();

    if (refreshRegisteredFolders) {
      await _loadPrefsAndAutoOpenFolder(pageIndex: _galleryPageIndex);
    } else {
      final currentFolderRaw = _currentFolderRaw;
      if (currentFolderRaw != null) {
        await _loadFolder(
          FolderHandle(currentFolderRaw),
          saveAsLast: false,
          pageIndex: _galleryPageIndex,
        );
      }
      await _reloadFavorites();
    }

    await _refreshAllFavoritesItems();
    await _reloadArtistTagMasters();
    await _refreshArtistTagCounts();

    _homeSearchCorpus = const <MediaItem>[];
    _homeSearchCorpusSignature = '';
    _dbTagsByItemId = <String, List<String>>{};
    _dbTagDetailsByItemId = <String, List<TagWithId>>{};

    if (_homeQuery.trim().isNotEmpty || _page == _MainPage.search) {
      _folderItemsCacheRecursive.clear();
      await _runHomeSearch(includeAllWhenEmpty: _page == _MainPage.search);
    } else if (mounted) {
      setState(() {
        _homeSearching = false;
        _homeSearchResults = const <MediaItem>[];
        _homeSearchErrorMessage = null;
      });
    }

    await _refreshHomeShowcases();
    await _refreshCurrentPageTags();
  }

  Future<void> _handlePullToRefresh() async {
    await _refreshVisibleContent(refreshRegisteredFolders: true);
  }

  bool get _canRequestRescan => !widget.tagService.settings.isStandaloneMode;

  Future<void> _requestRescanFromTopBar() async {
    if (_rescanning) {
      return;
    }
    if (!_canRequestRescan) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('スタンドアロンモードでは再スキャンは不要です')));
      return;
    }

    setState(() => _rescanning = true);
    try {
      await widget.tagService.requestRescan();
      await _refreshVisibleContent(refreshRegisteredFolders: true);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('再スキャンが完了しました')));
    } catch (error, stackTrace) {
      _logUiError('rescan', error, stackTrace);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('再スキャンに失敗しました: $error')));
    } finally {
      if (mounted) {
        setState(() => _rescanning = false);
      } else {
        _rescanning = false;
      }
    }
  }

  Widget _buildRescanAppBarButton() {
    return IconButton(
      tooltip: _rescanning ? '再スキャン中...' : '再スキャン',
      onPressed: _rescanning ? null : _requestRescanFromTopBar,
      icon: _rescanning
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.sync),
    );
  }

  List<Widget> _appendTopBarRescanAction(List<Widget> actions) {
    return <Widget>[...actions, _buildRescanAppBarButton()];
  }

  Future<void> _saveFolderTileMode(FolderTileMode m) async {
    setState(() => _folderTileMode = m);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_PrefsKeys.folderTileMode, m.index);
  }

  Future<Uint8List?> _getFolderPreviewBytes(MediaItem folderItem) {
    //if (!_thumbsEnabled) return Future.value(null);

    final key = folderItem.id;

    if (_folderPreviewCache.containsKey(key)) {
      return Future.value(_folderPreviewCacheGet(key));
    }

    final inflight = _folderPreviewInFlight[key];
    if (inflight != null) return inflight;

    Future<MediaItem?> pickCandidateInFolder(String folderRaw) async {
      const int pageLimit = 60;
      const int maxPages = 4;

      MediaItem? firstImage;

      for (int p = 0; p < maxPages; p++) {
        final res = await widget.repo.listMediaPage(
          FolderHandle(folderRaw),
          offset: p * pageLimit,
          limit: pageLimit,
        );

        for (final it in res.items) {
          if (it.kind == MediaKind.pdf) return it; // PDF蜆ｪ蜈・
          if (it.kind == MediaKind.image && firstImage == null) {
            firstImage = it;
          }
        }

        if (res.items.length < pageLimit) break;
      }

      return firstImage;
    }

    final fut = () async {
      await _acquireFolderPreviewSlot(1);
      try {
        final cand = await pickCandidateInFolder(folderItem.id);
        if (cand != null) {
          final pair = await widget.repo.readThumbPair(cand, maxWidth: 240);
          _folderPreviewCachePut(key, pair.front);
          return pair.front;
        }

        final firstPage = await widget.repo.listMediaPage(
          FolderHandle(folderItem.id),
          offset: 0,
          limit: 60,
        );

        int tried = 0;
        for (final it in firstPage.items) {
          if (it.kind != MediaKind.folder) continue;
          final cand2 = await pickCandidateInFolder(it.id);
          if (cand2 != null) {
            final pair = await widget.repo.readThumbPair(cand2, maxWidth: 240);
            _folderPreviewCachePut(key, pair.front);
            return pair.front;
          }
          tried++;
          if (tried >= 3) break;
        }

        _folderPreviewCachePut(key, null);
        return null;
      } catch (_) {
        _folderPreviewCachePut(key, null);
        return null;
      } finally {
        _releaseFolderPreviewSlot();
        _folderPreviewInFlight.remove(key);
      }
    }();

    _folderPreviewInFlight[key] = fut;
    return fut;
  }
  // ----------------
  // Tags (SharedPreferences萓晏ｭ・

  Future<void> _refreshCurrentPageTags([List<MediaItem>? source]) async {
    final targets = (source ?? _items)
        .where((item) => item.kind != MediaKind.folder)
        .toList(growable: false);

    if (targets.isEmpty) {
      if (!mounted) return;
      setState(() {
        _tagsById = <String, List<String>>{};
        _tagDetailsById = <String, List<TagWithId>>{};
        _currentPageMetadataAvailable = true;
      });
      return;
    }

    final details = await widget.tagService.getDetailedTagsByItems(targets);
    if (details.isEmpty && targets.isNotEmpty) {
      if (!mounted) return;
      setState(() {
        _tagsById = <String, List<String>>{};
        _tagDetailsById = <String, List<TagWithId>>{};
        _currentPageMetadataAvailable = false;
      });
      return;
    }
    if (!mounted) return;

    setState(() {
      _tagDetailsById = details;
      _tagsById = details.map(
        (key, value) => MapEntry(
          key,
          value.map((entry) => entry.tag.name).toList(growable: false),
        ),
      );
      _currentPageMetadataAvailable = true;
    });
  }

  List<String> _homeSearchTagsFor(MediaItem item) {
    for (final key in _idVariants(item.id)) {
      final tags = _dbTagsByItemId[key];
      if (tags != null) {
        return tags;
      }
    }
    return const <String>[];
  }

  List<TagWithId> _homeSearchTagDetailsFor(MediaItem item) {
    for (final key in _idVariants(item.id)) {
      final details = _dbTagDetailsByItemId[key];
      if (details != null) {
        return details;
      }
    }
    return const <TagWithId>[];
  }

  String _buildHomeSearchCorpusSignature(List<MediaItem> items) {
    var hash = 0x811C9DC5;
    for (final item in items) {
      hash = 0x1fffffff & (hash ^ item.id.hashCode ^ item.displayName.hashCode);
      hash = 0x1fffffff & (hash + item.kind.index + item.folderRaw.hashCode);
    }
    return '${_foldersRaw.length}:$hash:${items.length}';
  }

  Future<List<MediaItem>> _ensureHomeSearchCorpusLoaded() async {
    for (final raw in _foldersRaw) {
      if (_folderItemsCacheRecursive.containsKey(raw)) continue;
      try {
        final list = await widget.repo.listMediaRecursiveFiles(
          FolderHandle(raw),
        );
        _folderItemsCacheRecursive[raw] = list
            .where((item) => item.kind != MediaKind.folder)
            .toList(growable: false);
      } catch (_) {
        _folderItemsCacheRecursive[raw] = const <MediaItem>[];
      }
    }

    final all = <MediaItem>[];
    for (final raw in _foldersRaw) {
      final list = _folderItemsCacheRecursive[raw] ?? const <MediaItem>[];
      all.addAll(list);
    }

    final signature = _buildHomeSearchCorpusSignature(all);
    if (_homeSearchCorpusSignature == signature &&
        _homeSearchCorpus.length == all.length) {
      return _homeSearchCorpus;
    }

    widget.tagService.rememberItems(all);
    final details = await widget.tagService.getDetailedTagsByItems(all);

    final expandedNames = <String, List<String>>{};
    final expandedDetails = <String, List<TagWithId>>{};
    details.forEach((key, value) {
      final names = value
          .map((entry) => entry.tag.name)
          .toList(growable: false);
      for (final variant in _idVariants(key)) {
        expandedNames[variant] = names;
        expandedDetails[variant] = value;
      }
    });

    _homeSearchCorpus = all.toList(growable: false);
    _homeSearchCorpusSignature = signature;
    _dbTagsByItemId = expandedNames;
    _dbTagDetailsByItemId = expandedDetails;
    return _homeSearchCorpus;
  }

  bool _matchHomeQuery(MediaItem item, String qRaw) {
    final q = qRaw.trim().toLowerCase();
    if (q.isEmpty) return true;

    final tokens = q.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
    final name = item.displayName.toLowerCase();
    final tags = _homeSearchTagsFor(
      item,
    ).map((entry) => entry.toLowerCase()).toList(growable: false);
    final detailedTags = _homeSearchTagDetailsFor(item);

    bool matchToken(String t) {
      if (t == 'untagged' || t == '未分類') {
        return detailedTags.isEmpty;
      }
      final separator = t.indexOf(':');
      if (separator > 0 && separator < t.length - 1) {
        final key = t.substring(0, separator);
        final value = t.substring(separator + 1);
        final category = _tagCategoryForSearchKey(key);
        if (category != null) {
          return detailedTags.any(
            (tag) =>
                tag.tag.category == category &&
                tag.tag.name.toLowerCase().contains(value),
          );
        }
      }

      if (t.startsWith('#')) {
        final needle = t.substring(1);
        if (needle.isEmpty) return true;
        return tags.any((x) => x.contains(needle));
      }

      return name.contains(t) || tags.any((x) => x.contains(t));
    }

    for (final t in tokens) {
      if (!matchToken(t)) return false;
    }
    return true;
  }

  List<MediaItem> _sortItemsByMode(
    Iterable<MediaItem> items, {
    required _SortMode sortMode,
  }) {
    final sorted = items.toList(growable: true);
    switch (sortMode) {
      case _SortMode.name:
        sorted.sort(
          (a, b) => a.displayName.toLowerCase().compareTo(
            b.displayName.toLowerCase(),
          ),
        );
        break;
      case _SortMode.updatedAt:
        sorted.sort((a, b) => _getUpdatedAt(b).compareTo(_getUpdatedAt(a)));
        break;
      case _SortMode.addedAt:
        sorted.sort((a, b) => _getAddedAt(b).compareTo(_getAddedAt(a)));
        break;
    }
    return sorted.toList(growable: false);
  }

  Future<void> _runHomeSearch({bool includeAllWhenEmpty = false}) async {
    final q = _homeQuery.trim();
    if (!_repoCapabilities.canRecursiveSearch) {
      if (!mounted) return;
      setState(() {
        _homeSearching = false;
        _homeSearchResults = const [];
        _homeSearchErrorMessage = null;
        _homeSearchPageIndex = 0;
      });
      return;
    }

    if (q.isEmpty && !includeAllWhenEmpty) {
      if (!mounted) return;
      setState(() {
        _homeSearching = false;
        _homeSearchResults = const [];
        _homeSearchErrorMessage = null;
        _homeSearchPageIndex = 0;
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      _homeSearching = true;
      _homeSearchErrorMessage = null;
    });

    try {
      final all = await _ensureHomeSearchCorpusLoaded();
      final filtered = q.isEmpty
          ? all.toList(growable: false)
          : all
                .where((item) => _matchHomeQuery(item, q))
                .toList(growable: false);
      final sorted = _sortItemsByMode(filtered, sortMode: _homeSearchSortMode);

      if (!mounted) return;
      setState(() {
        _homeSearching = false;
        _homeSearchResults = sorted;
        _homeSearchErrorMessage = null;
        _homeSearchPageIndex = 0;
      });
    } catch (e, st) {
      _logUiError('home-search', e, st);

      if (!mounted) return;
      setState(() {
        _homeSearching = false;
        _homeSearchResults = const [];
        _homeSearchErrorMessage = '全フォルダ検索でエラーが発生しました: $e';
      });

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('全フォルダ検索でエラー: $e')));
    }
  }

  Future<void> _openDetailedBrowsePage() async {
    if (!_repoCapabilities.canRecursiveSearch) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('このモードでは詳細ブラウズは未対応です')));
      return;
    }
    if (mounted) {
      setState(() => _page = _MainPage.search);
    } else {
      _page = _MainPage.search;
    }
    await _runHomeSearch(includeAllWhenEmpty: true);
  }

  Future<void> _refreshDetailedBrowseIfNeeded() async {
    if (_homeQuery.trim().isNotEmpty || _page == _MainPage.search) {
      await _runHomeSearch(includeAllWhenEmpty: _page == _MainPage.search);
    }
  }

  void _handleHomeSearchTextChanged({
    required String value,
    required bool includeAllWhenEmpty,
  }) {
    setState(() {
      _homeQuery = value;
      _homeSearchPageIndex = 0;
    });

    _homeSearchDebounce?.cancel();
    _homeSearchDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      _runHomeSearch(includeAllWhenEmpty: includeAllWhenEmpty);
    });
  }

  Widget _buildSharedHomeSearchField({
    required bool includeAllWhenEmpty,
    String? hintText,
  }) {
    return TextField(
      controller: _homeSearchCtrl,
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search),
        hintText: hintText ?? 'タイトル / #タグ / artist:xxx / series:yyy',
        border: const OutlineInputBorder(),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 10),
        suffixIcon: (_homeQuery.trim().isEmpty)
            ? null
            : IconButton(
                tooltip: 'クリア',
                icon: const Icon(Icons.clear),
                onPressed: () {
                  _homeSearchCtrl.clear();
                  setState(() => _homeQuery = '');
                  _runHomeSearch(includeAllWhenEmpty: includeAllWhenEmpty);
                },
              ),
      ),
      onChanged: (value) => _handleHomeSearchTextChanged(
        value: value,
        includeAllWhenEmpty: includeAllWhenEmpty,
      ),
    );
  }

  List<String> _homeSearchValuesForCategory(
    MediaItem item,
    TagCategory category,
  ) {
    final values = <String>[];
    final seen = <String>{};
    for (final entry in _homeSearchTagDetailsFor(item)) {
      if (entry.tag.category != category) {
        continue;
      }
      final trimmed = entry.tag.name.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      final key = trimmed.toLowerCase();
      if (seen.add(key)) {
        values.add(trimmed);
      }
    }
    return values;
  }

  String _homeSearchPrimaryValueForCategory(
    MediaItem item,
    TagCategory category, {
    int maxValues = 2,
    String emptyLabel = 'N/A',
  }) {
    final values = _homeSearchValuesForCategory(item, category);
    if (values.isEmpty) {
      return emptyLabel;
    }
    return values.take(maxValues).join(' / ');
  }

  String _formatDetailedBrowseDate(DateTime? value) {
    if (value == null) {
      return '不明';
    }
    final local = value.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '${local.year}/$month/$day $hour:$minute';
  }

  Color _detailedBrowseAccentColor(BuildContext context, MediaItem item) {
    final scheme = Theme.of(context).colorScheme;
    switch (item.kind) {
      case MediaKind.pdf:
        return scheme.primaryContainer;
      case MediaKind.image:
        return scheme.tertiaryContainer;
      case MediaKind.folder:
        return scheme.secondaryContainer;
    }
  }

  Color _detailedBrowseAccentTextColor(BuildContext context, MediaItem item) {
    final scheme = Theme.of(context).colorScheme;
    switch (item.kind) {
      case MediaKind.pdf:
        return scheme.onPrimaryContainer;
      case MediaKind.image:
        return scheme.onTertiaryContainer;
      case MediaKind.folder:
        return scheme.onSecondaryContainer;
    }
  }

  Widget _buildDetailedBrowseThumb(MediaItem item) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: FutureBuilder<ThumbPair>(
        future: widget.repo.readThumbPair(item, maxWidth: 320),
        builder: (context, snap) {
          if (snap.hasError) {
            return Container(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              alignment: Alignment.center,
              child: const Icon(Icons.broken_image_outlined),
            );
          }
          if (!snap.hasData) {
            return Container(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              alignment: Alignment.center,
              child: const CircularProgressIndicator(strokeWidth: 2),
            );
          }

          return Image.memory(
            snap.data!.front,
            fit: BoxFit.cover,
            gaplessPlayback: true,
          );
        },
      ),
    );
  }

  String _detailedBrowseTileSubtitle(MediaItem item) {
    final artist = _homeSearchPrimaryValueForCategory(
      item,
      TagCategory.artist,
      maxValues: 1,
      emptyLabel: '',
    );
    if (artist.isNotEmpty) {
      return artist;
    }

    final series = _homeSearchPrimaryValueForCategory(
      item,
      TagCategory.series,
      maxValues: 1,
      emptyLabel: '',
    );
    if (series.isNotEmpty) {
      return series;
    }

    return _folderLabelForItem(item);
  }

  Widget _buildDetailedBrowseGridTile(MediaItem item) {
    final theme = Theme.of(context);
    final subtitle = _detailedBrowseTileSubtitle(item);
    final folderLabel = _folderLabelForItem(item);
    final updatedAt = _formatDetailedBrowseDate(
      item.modified ?? _getUpdatedAt(item),
    );
    final isSelected = _selectedIds.contains(item.id);
    final isFavorite = _favorites.contains(item.id);
    final accent = _detailedBrowseAccentColor(context, item);
    final accentText = _detailedBrowseAccentTextColor(context, item);

    return ControllerFocusable(
      debugLabel: 'browse-grid-${item.id}',
      borderRadius: BorderRadius.circular(18),
      onLongPress: () {
        if (!_selectMode) {
          _enterSelectMode(item);
        } else {
          _toggleSelect(item);
        }
      },
      onPressed: () async {
        if (_selectMode) {
          _toggleSelect(item);
          return;
        }
        await _openDetailFromHome(item);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: isSelected
              ? Border.all(color: theme.colorScheme.primary, width: 2)
              : null,
          color: isSelected
              ? theme.colorScheme.primary.withValues(alpha: 0.04)
              : Colors.transparent,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(child: _buildDetailedBrowseThumb(item)),
                  Positioned(
                    top: 8,
                    left: 8,
                    child: item.kind == MediaKind.pdf
                        ? const _PdfBadge()
                        : const SizedBox.shrink(),
                  ),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: _FavButton(
                      isFavorite: isFavorite,
                      onPressed: () => _toggleFavorite(item),
                    ),
                  ),
                  Positioned(
                    left: 8,
                    right: 8,
                    bottom: 8,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.88),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 5,
                        ),
                        child: Text(
                          folderLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: accentText,
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (isSelected)
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        padding: const EdgeInsets.all(8),
                        alignment: Alignment.topRight,
                        child: const Icon(
                          Icons.check_circle,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _displayTitleForItem(item),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
                height: 1.2,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              updatedAt,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: accent.withValues(alpha: 0.95),
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  int _detailedBrowseTotalPages() {
    if (_homeSearchResults.isEmpty) return 0;
    return (_homeSearchResults.length + _pageSize - 1) ~/ _pageSize;
  }

  int _detailedBrowseClampedPageIndex() {
    final totalPages = _detailedBrowseTotalPages();
    if (totalPages <= 1) return 0;
    return _homeSearchPageIndex.clamp(0, totalPages - 1);
  }

  List<MediaItem> _currentDetailedBrowsePageItems() {
    if (_homeSearchResults.isEmpty) return const <MediaItem>[];

    final pageIndex = _detailedBrowseClampedPageIndex();
    final start = pageIndex * _pageSize;
    final end = start + _pageSize;

    return _homeSearchResults.sublist(
      start,
      end > _homeSearchResults.length ? _homeSearchResults.length : end,
    );
  }

  Widget _buildDetailedBrowsePager() {
    if (_homeSearchResults.length <= _pageSize) {
      return const SizedBox.shrink();
    }

    final totalPages = _detailedBrowseTotalPages();
    final clamped = _detailedBrowseClampedPageIndex();
    final start = clamped * _pageSize + 1;
    final end = ((clamped + 1) * _pageSize).clamp(0, _homeSearchResults.length);
    final useDropdown = totalPages > 10;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Row(
        children: [
          Text('$start-$end / ${_homeSearchResults.length}'),
          const Spacer(),
          if (useDropdown)
            DropdownButton<int>(
              value: clamped,
              items: List.generate(
                totalPages,
                (index) => DropdownMenuItem<int>(
                  value: index,
                  child: Text('ページ ${index + 1}'),
                ),
              ),
              onChanged: (value) {
                if (value == null || value == clamped) return;
                setState(() => _homeSearchPageIndex = value);
              },
            )
          else
            Flexible(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: List.generate(totalPages, (index) {
                    final selected = index == clamped;
                    return Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: ChoiceChip(
                        label: Text('${index + 1}'),
                        selected: selected,
                        onSelected: (_) {
                          if (selected) return;
                          setState(() => _homeSearchPageIndex = index);
                        },
                      ),
                    );
                  }),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDetailedBrowseResultsBody() {
    Widget headerCard() {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '詳細ブラウズ',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(
                _homeQuery.trim().isEmpty
                    ? 'キーワードなしでも最近の項目を一覧できます。検索すると作家・シリーズ・タグで絞り込めます。'
                    : '作家・シリーズ・タグを含む詳細カードで、PDF や画像を選びやすく表示します。',
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 44,
                child: _buildSharedHomeSearchField(includeAllWhenEmpty: true),
              ),
              const SizedBox(height: 10),
              LayoutBuilder(
                builder: (context, constraints) {
                  final dropdown = DropdownButton<_SortMode>(
                    value: _homeSearchSortMode,
                    items: const [
                      DropdownMenuItem(
                        value: _SortMode.updatedAt,
                        child: Text('更新日'),
                      ),
                      DropdownMenuItem(
                        value: _SortMode.addedAt,
                        child: Text('追加日'),
                      ),
                      DropdownMenuItem(
                        value: _SortMode.name,
                        child: Text('名前'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() {
                        _homeSearchSortMode = value;
                        _homeSearchResults = _sortItemsByMode(
                          _homeSearchResults,
                          sortMode: _homeSearchSortMode,
                        );
                        _homeSearchPageIndex = 0;
                      });
                    },
                  );

                  if (constraints.maxWidth < 520) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('表示件数: ${_homeSearchResults.length} 件'),
                        Row(
                          children: [
                            const Text('並び替え'),
                            const SizedBox(width: 8),
                            dropdown,
                          ],
                        ),
                      ],
                    );
                  }

                  return Row(
                    children: [
                      Text('表示件数: ${_homeSearchResults.length} 件'),
                      const Spacer(),
                      const Text('並び替え'),
                      const SizedBox(width: 8),
                      dropdown,
                    ],
                  );
                },
              ),
              if (_homeSearching) ...[
                const SizedBox(height: 10),
                const LinearProgressIndicator(),
              ],
            ],
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        const crossAxisCount = 3;
        final pageItems = _currentDetailedBrowsePageItems();
        final showPager = _homeSearchResults.length > _pageSize;
        final crossSpacing = constraints.maxWidth < 420 ? 8.0 : 12.0;
        final mainSpacing = constraints.maxWidth < 420 ? 14.0 : 18.0;
        final contentWidth = constraints.maxWidth <= 760
            ? (constraints.maxWidth - 24).clamp(0.0, double.infinity).toDouble()
            : 760.0;
        final sidePadding = (constraints.maxWidth - contentWidth) / 2;
        final tileWidth =
            (contentWidth - (crossSpacing * (crossAxisCount - 1))) /
            crossAxisCount;
        final tileHeight = (tileWidth * (4 / 3)) + 84;

        return RefreshIndicator(
          onRefresh: _handlePullToRefresh,
          child: CustomScrollView(
            physics: _refreshScrollPhysics,
            cacheExtent: 400,
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(sidePadding, 12, sidePadding, 12),
                sliver: SliverToBoxAdapter(child: headerCard()),
              ),
              if (_homeSearchErrorMessage != null)
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(sidePadding, 0, sidePadding, 12),
                  sliver: SliverToBoxAdapter(
                    child: _buildErrorBody(
                      title: '詳細ブラウズの読み込みに失敗しました',
                      message: _homeSearchErrorMessage!,
                      onAction: () => _runHomeSearch(includeAllWhenEmpty: true),
                    ),
                  ),
                )
              else if (!_homeSearching && _homeSearchResults.isEmpty)
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(sidePadding, 0, sidePadding, 12),
                  sliver: SliverToBoxAdapter(
                    child: _buildEmptyBody(
                      title: '表示できる項目がありません',
                      message: _homeQuery.trim().isEmpty
                          ? '登録フォルダ内に表示対象の PDF / 画像がありません。'
                          : '別のキーワード、タグ、artist / series 指定を試してください。',
                    ),
                  ),
                )
              else ...[
                if (showPager)
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      sidePadding,
                      0,
                      sidePadding,
                      12,
                    ),
                    sliver: SliverToBoxAdapter(
                      child: _buildDetailedBrowsePager(),
                    ),
                  ),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(sidePadding, 0, sidePadding, 12),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: crossAxisCount,
                      mainAxisSpacing: mainSpacing,
                      crossAxisSpacing: crossSpacing,
                      mainAxisExtent: tileHeight,
                    ),
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final item = pageItems[index];
                      return _buildDetailedBrowseGridTile(item);
                    }, childCount: pageItems.length),
                  ),
                ),
                if (showPager)
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      sidePadding,
                      0,
                      sidePadding,
                      12,
                    ),
                    sliver: SliverToBoxAdapter(
                      child: _buildDetailedBrowsePager(),
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _organizeLibrary() async {
    try {
      final lib = await widget.repo.getAppLibraryFolder();
      final moved = await widget.tagService.organizeAppLibrary(
        libraryRoot: lib.raw,
      );

      if (!mounted) return;

      if (_currentFolderRaw != null && _currentFolderRaw!.startsWith(lib.raw)) {
        await _loadFolder(FolderHandle(_currentFolderRaw!), saveAsLast: false);
      }

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ライブラリ整理完了: 移動 ${moved.length} 件')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('ライブラリ整理に失敗しました: $e')));
    }
  }

  Widget _homeFavThumb(MediaItem item, {bool fill = false}) {
    final thumb = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: FutureBuilder<ThumbPair>(
        future: widget.repo.readThumbPair(item, maxWidth: 240),
        builder: (context, snap) {
          if (snap.hasError) {
            return Container(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              alignment: Alignment.center,
              child: const Icon(Icons.broken_image_outlined),
            );
          }
          if (!snap.hasData) {
            return Container(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              alignment: Alignment.center,
              child: const CircularProgressIndicator(strokeWidth: 2),
            );
          }

          return Image.memory(
            snap.data!.front,
            fit: BoxFit.cover,
            gaplessPlayback: true,
          );
        },
      ),
    );

    if (fill) {
      return thumb;
    }

    return AspectRatio(aspectRatio: 3 / 4, child: thumb);
  }

  bool _isFavoriteItem(MediaItem item) {
    for (final variant in _idVariants(item.id)) {
      if (_favorites.contains(variant)) {
        return true;
      }
      if (_favoriteResolvedIds.contains(variant)) {
        return true;
      }
    }
    return false;
  }

  ReadingProgressEntry? _homeRecentViewEntryForItem(MediaItem item) {
    for (final variant in _idVariants(item.id)) {
      final entry = _homeRecentViewEntriesByItemId[variant];
      if (entry != null) {
        return entry;
      }
    }
    return null;
  }

  DateTime _homeAddedTimestamp(MediaItem item) {
    final added = _getAddedAt(item);
    if (added.millisecondsSinceEpoch > 0) {
      return added;
    }
    final updated = item.modified ?? _getUpdatedAt(item);
    if (updated.millisecondsSinceEpoch > 0) {
      return updated;
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  String _formatHomeDateTime(DateTime? value) {
    if (value == null || value.millisecondsSinceEpoch <= 0) {
      return '日時未取得';
    }
    final local = value.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '${local.year}/$month/$day $hour:$minute';
  }

  Future<List<MediaItem>> _ensureHomeShelfCorpusLoaded() async {
    if (_repoCapabilities.canRecursiveSearch) {
      return _ensureHomeSearchCorpusLoaded();
    }

    for (final raw in _foldersRaw) {
      if (_folderItemsCache.containsKey(raw)) {
        continue;
      }
      try {
        _folderItemsCache[raw] = await widget.repo.listMedia(FolderHandle(raw));
      } catch (_) {
        _folderItemsCache[raw] = const <MediaItem>[];
      }
    }

    final all = <MediaItem>[];
    for (final raw in _foldersRaw) {
      final items = _folderItemsCache[raw] ?? const <MediaItem>[];
      all.addAll(items.where((item) => item.kind != MediaKind.folder));
    }

    final signature = _buildHomeSearchCorpusSignature(all);
    if (_homeSearchCorpusSignature == signature &&
        _homeSearchCorpus.length == all.length) {
      return _homeSearchCorpus;
    }

    widget.tagService.rememberItems(all);
    final details = await widget.tagService.getDetailedTagsByItems(all);

    final expandedNames = <String, List<String>>{};
    final expandedDetails = <String, List<TagWithId>>{};
    details.forEach((key, value) {
      final names = value
          .map((entry) => entry.tag.name)
          .toList(growable: false);
      for (final variant in _idVariants(key)) {
        expandedNames[variant] = names;
        expandedDetails[variant] = value;
      }
    });

    _homeSearchCorpus = all.toList(growable: false);
    _homeSearchCorpusSignature = signature;
    _dbTagsByItemId = expandedNames;
    _dbTagDetailsByItemId = expandedDetails;
    return _homeSearchCorpus;
  }

  Future<void> _refreshHomeShowcases() async {
    final loadVersion = ++_homeShowcaseLoadVersion;
    if (mounted) {
      setState(() {
        _homeShowcaseLoading = true;
        _homeShowcaseErrorMessage = null;
      });
    } else {
      _homeShowcaseLoading = true;
      _homeShowcaseErrorMessage = null;
    }

    try {
      if (_foldersRaw.isEmpty) {
        if (!mounted || loadVersion != _homeShowcaseLoadVersion) {
          return;
        }
        setState(() {
          _homeRecentAddedItems = const <MediaItem>[];
          _homeUnreadItems = const <MediaItem>[];
          _homeFavoriteShowcaseItems = const <MediaItem>[];
          _homeRecentViewedItems = const <MediaItem>[];
          _homeRecentViewEntriesByItemId = <String, ReadingProgressEntry>{};
          _homeResumeCard = null;
          _homeShowcaseErrorMessage = null;
        });
        return;
      }

      final recentProgress = await _readingProgressService.fetchRecent(
        limit: 200,
      );
      final allItems = await _ensureHomeShelfCorpusLoaded();
      final mediaItems = allItems
          .where((item) => item.kind != MediaKind.folder)
          .toList(growable: false);

      final recentAdded = mediaItems.toList(growable: true)
        ..sort(
          (a, b) => _homeAddedTimestamp(b).compareTo(_homeAddedTimestamp(a)),
        );

      final itemByVariant = await _buildHomeItemLookup(
        mediaItems,
        recentProgress,
      );

      final recentViewedItems = <MediaItem>[];
      final recentViewEntriesByItemId = <String, ReadingProgressEntry>{};
      _HomeResumeCardData? resumeCard;

      for (final entry in recentProgress) {
        final resolved =
            itemByVariant[entry.mediaId] ??
            itemByVariant[_readingProgressLookupKey(
              entry.folderRaw,
              entry.title,
            )];
        if (resolved == null) {
          continue;
        }

        if (!recentViewEntriesByItemId.containsKey(resolved.id)) {
          recentViewEntriesByItemId[resolved.id] = entry;
          recentViewedItems.add(resolved);
        }

        if (resumeCard == null &&
            resolved.kind == MediaKind.pdf &&
            ReadingProgressService.shouldShowContinueCard(entry)) {
          resumeCard = _HomeResumeCardData(item: resolved, progress: entry);
        }
      }

      final favorites = mediaItems.where(_isFavoriteItem).toList(growable: true)
        ..sort(
          (a, b) => _homeAddedTimestamp(b).compareTo(_homeAddedTimestamp(a)),
        );
      final unreadItems = recentAdded
          .where(
            (item) =>
                item.kind == MediaKind.pdf &&
                !recentViewEntriesByItemId.containsKey(item.id),
          )
          .toList(growable: false);

      if (!mounted || loadVersion != _homeShowcaseLoadVersion) {
        return;
      }

      setState(() {
        _homeRecentAddedItems = recentAdded.take(10).toList(growable: false);
        _homeUnreadItems = unreadItems.take(10).toList(growable: false);
        _homeFavoriteShowcaseItems = favorites.take(10).toList(growable: false);
        _homeRecentViewedItems = recentViewedItems
            .take(10)
            .toList(growable: false);
        _homeRecentViewEntriesByItemId = recentViewEntriesByItemId;
        _homeResumeCard = resumeCard;
        _homeShowcaseErrorMessage = null;
      });
    } catch (error, stackTrace) {
      _logUiError('home-showcases', error, stackTrace);
      if (!mounted || loadVersion != _homeShowcaseLoadVersion) {
        return;
      }
      setState(() {
        _homeShowcaseErrorMessage = 'ホーム情報の更新に失敗しました: $error';
      });
    } finally {
      if (mounted && loadVersion == _homeShowcaseLoadVersion) {
        setState(() => _homeShowcaseLoading = false);
      } else if (loadVersion == _homeShowcaseLoadVersion) {
        _homeShowcaseLoading = false;
      }
    }
  }

  Widget _buildHomeSectionHeading(String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: Colors.white70),
        ),
      ],
    );
  }

  Widget _buildHomeShelfMetaLine(String label, String value) {
    return Text(
      '$label: $value',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(
        context,
      ).textTheme.bodySmall?.copyWith(color: Colors.white70),
    );
  }

  Widget _buildHomeShelfEmptyState({
    required IconData icon,
    required String title,
    required String message,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      child: Row(
        children: [
          Icon(icon, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Colors.white70),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHomeMediaShelfCard({
    required MediaItem item,
    required String footerText,
    required IconData footerIcon,
    required VoidCallback onTap,
    String? badgeText,
    IconData? badgeIcon,
    Color? badgeBackgroundColor,
    Color? badgeForegroundColor,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final artist = _homeSearchPrimaryValueForCategory(
      item,
      TagCategory.artist,
      maxValues: 1,
      emptyLabel: '未設定',
    );
    final series = _homeSearchPrimaryValueForCategory(
      item,
      TagCategory.series,
      maxValues: 1,
      emptyLabel: '未設定',
    );
    final width = MediaQuery.of(context).size.width < 560 ? 168.0 : 188.0;

    return SizedBox(
      width: width,
      child: Card(
        clipBehavior: Clip.antiAlias,
        margin: EdgeInsets.zero,
        child: ControllerFocusable(
          debugLabel: 'home-shelf-${item.id}',
          borderRadius: BorderRadius.circular(14),
          onPressed: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _homeFavThumb(item, fill: true),
                      Positioned(
                        left: 8,
                        top: 8,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: _detailedBrowseAccentColor(context, item),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            child: Text(
                              item.kind == MediaKind.pdf ? 'PDF' : '画像',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: _detailedBrowseAccentTextColor(
                                  context,
                                  item,
                                ),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (badgeText != null && badgeText.trim().isNotEmpty)
                        Positioned(
                          right: 8,
                          top: 8,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color:
                                  badgeBackgroundColor ??
                                  scheme.primaryContainer,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (badgeIcon != null) ...[
                                    Icon(
                                      badgeIcon,
                                      size: 12,
                                      color:
                                          badgeForegroundColor ??
                                          scheme.onPrimaryContainer,
                                    ),
                                    const SizedBox(width: 4),
                                  ],
                                  Text(
                                    badgeText,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color:
                                          badgeForegroundColor ??
                                          scheme.onPrimaryContainer,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _displayTitleForItem(item),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                _buildHomeShelfMetaLine('作者', artist),
                const SizedBox(height: 4),
                _buildHomeShelfMetaLine('シリーズ', series),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(footerIcon, size: 14, color: Colors.white70),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        footerText,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.white70,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHomeMediaShelf({
    required String title,
    required String subtitle,
    required List<MediaItem> items,
    required String emptyTitle,
    required String emptyMessage,
    required Widget Function(MediaItem item) itemBuilder,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHomeSectionHeading(title, subtitle),
            const SizedBox(height: 10),
            if (_homeShowcaseLoading && items.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (items.isEmpty)
              _buildHomeShelfEmptyState(
                icon: Icons.photo_library_outlined,
                title: emptyTitle,
                message: emptyMessage,
              )
            else
              _HomeShelfScroller(
                itemCount: items.length,
                itemBuilder: (context, index) => itemBuilder(items[index]),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildContinueReadingCard() {
    final resume = _homeResumeCard;
    if (resume == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHomeSectionHeading('続きから読む', '前回見ていた PDF をそのページから開けます。'),
              const SizedBox(height: 10),
              _buildHomeShelfEmptyState(
                icon: Icons.auto_stories_outlined,
                title: '再開できる PDF がありません',
                message: 'PDF を開いてページを進めると、ここから続きが再開できます。',
              ),
            ],
          ),
        ),
      );
    }

    final item = resume.item;
    final progress = resume.progress;
    final page = progress.currentPage;
    final totalPages = progress.totalPages;
    final pageText = totalPages != null ? 'p.$page / $totalPages' : 'p.$page';
    final progressText = '${(progress.progress * 100).round()}%';
    final artist = _homeSearchPrimaryValueForCategory(
      item,
      TagCategory.artist,
      maxValues: 1,
      emptyLabel: '未設定',
    );
    final series = _homeSearchPrimaryValueForCategory(
      item,
      TagCategory.series,
      maxValues: 1,
      emptyLabel: '未設定',
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHomeSectionHeading('続きから読む', '最後に見ていた PDF をワンタップで再開できます。'),
            const SizedBox(height: 10),
            ControllerFocusable(
              debugLabel: 'continue-reading-${item.id}',
              borderRadius: BorderRadius.circular(14),
              onPressed: () => _openDetailFromHome(item, initialPdfPage: page),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final narrow = constraints.maxWidth < 600;
                    final thumb = SizedBox(
                      width: narrow ? 112 : 132,
                      child: _homeFavThumb(item),
                    );
                    final body = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${_displayTitleForItem(item)} p.$page から再開',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 8),
                        _buildHomeShelfMetaLine('作者', artist),
                        const SizedBox(height: 4),
                        _buildHomeShelfMetaLine('シリーズ', series),
                        const SizedBox(height: 4),
                        _buildHomeShelfMetaLine(
                          '前回閲覧',
                          _formatHomeDateTime(progress.lastReadAt),
                        ),
                        const SizedBox(height: 4),
                        _buildHomeShelfMetaLine(
                          '進捗',
                          '$pageText / $progressText',
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: () =>
                              _openDetailFromHome(item, initialPdfPage: page),
                          icon: const Icon(Icons.play_arrow_rounded),
                          label: Text('$pageText から開く'),
                        ),
                      ],
                    );

                    if (narrow) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [thumb, const SizedBox(height: 12), body],
                      );
                    }

                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        thumb,
                        const SizedBox(width: 14),
                        Expanded(child: body),
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHomeBody() {
    if (_initializing) {
      return _buildRefreshableStatusBody(
        onRefresh: _handlePullToRefresh,
        child: _buildLoadingBody(
          title: 'ホームを読み込み中',
          message: '登録フォルダやホーム用の一覧を準備しています。',
        ),
      );
    }

    if (_initializationErrorMessage != null) {
      return _buildRefreshableStatusBody(
        onRefresh: _handlePullToRefresh,
        child: _buildErrorBody(
          title: 'ホームの初期化に失敗しました',
          message: _initializationErrorMessage!,
          onAction: _retryInitialization,
        ),
      );
    }

    final folderCount = _foldersRaw.length;
    final currentLabel = _currentFolderRaw == null
        ? '未選択'
        : _folderLabel(_currentFolderRaw!);
    final homeSearchPreview = _homeSearchResults
        .take(4)
        .toList(growable: false);
    final recentViewedEntries = _homeRecentViewEntriesByItemId;

    return RefreshIndicator(
      onRefresh: _handlePullToRefresh,
      child: ListView(
        physics: _refreshScrollPhysics,
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'ホーム検索',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 44,
                    child: _buildSharedHomeSearchField(
                      includeAllWhenEmpty: false,
                    ),
                  ),
                  const SizedBox(height: 10),

                  if (_homeSearching)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: CircularProgressIndicator(),
                      ),
                    )
                  else if (!_repoCapabilities.canRecursiveSearch)
                    const Text('このモードでは全フォルダ検索は利用できません。')
                  else if (_homeSearchErrorMessage != null)
                    Text(
                      _homeSearchErrorMessage!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    )
                  else if (_homeQuery.trim().isEmpty)
                    const Text('タイトル、タグ、作者、シリーズで検索できます。')
                  else if (_homeSearchResults.isEmpty)
                    const Text('一致する作品はありません。')
                  else ...[
                    Text('件数: ${_homeSearchResults.length} 件'),
                    const SizedBox(height: 8),
                    ...homeSearchPreview.map((item) {
                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 6),
                        child: ControllerFocusable(
                          debugLabel: 'home-search-${item.id}',
                          borderRadius: BorderRadius.circular(14),
                          onPressed: () => _openDetailFromHome(item),
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  height: 96,
                                  child: _homeFavThumb(item),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _displayTitleForItem(item),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleMedium,
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        item.kind == MediaKind.pdf
                                            ? 'PDF'
                                            : '画像',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall,
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        'フォルダ: ${_folderLabelForItem(item)}',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }),
                    if (_homeSearchResults.length > homeSearchPreview.length)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: OutlinedButton.icon(
                            onPressed: () => _openDetailedBrowsePage(),
                            icon: const Icon(Icons.view_agenda_outlined),
                            label: const Text('詳細ブラウズで続きを見る'),
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'ライブラリ',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text('登録フォルダ数: $folderCount'),
                  Text('現在のフォルダ: $currentLabel'),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ElevatedButton.icon(
                        onPressed: _addFolder,
                        icon: Icon(_primaryAddActionIcon),
                        label: Text(_primaryAddActionLabel),
                      ),
                      OutlinedButton.icon(
                        onPressed: (_currentFolderRaw == null)
                            ? null
                            : () => setState(() => _page = _MainPage.gallery),
                        icon: const Icon(Icons.grid_view),
                        label: const Text('ギャラリーを開く'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _repoCapabilities.canRecursiveSearch
                            ? () => _openDetailedBrowsePage()
                            : null,
                        icon: const Icon(Icons.view_agenda_outlined),
                        label: const Text('詳細ブラウズ'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _refreshAllFavoritesItems,
                        icon: const Icon(Icons.star),
                        label: const Text('お気に入り更新'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (_homeShowcaseErrorMessage != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _homeShowcaseErrorMessage!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (_homeShowcaseErrorMessage != null) const SizedBox(height: 12),
          _buildHomeMediaShelf(
            title: 'お気に入り',
            subtitle: 'お気に入り登録した作品をすぐ開けます。',
            items: _homeFavoriteShowcaseItems,
            emptyTitle: 'お気に入りはまだありません',
            emptyMessage: '作品をお気に入りにすると、ここへ表紙つきで並びます。',
            itemBuilder: (item) {
              final activity = _homeRecentViewEntryForItem(item);
              return _buildHomeMediaShelfCard(
                item: item,
                footerText: activity == null
                    ? '追加 ${_formatHomeDateTime(_homeAddedTimestamp(item))}'
                    : '最終閲覧 ${_formatHomeDateTime(activity.lastReadAt)}',
                footerIcon: activity == null
                    ? Icons.schedule_outlined
                    : Icons.history,
                badgeText: 'お気に入り',
                badgeIcon: Icons.star_rounded,
                badgeBackgroundColor: Theme.of(
                  context,
                ).colorScheme.primaryContainer,
                badgeForegroundColor: Theme.of(
                  context,
                ).colorScheme.onPrimaryContainer,
                onTap: () => _openDetailFromHome(item),
              );
            },
          ),
          const SizedBox(height: 12),
          _buildHomeMediaShelf(
            title: '最近追加',
            subtitle: '追加された作品を表紙つきで一覧できます。',
            items: _homeRecentAddedItems,
            emptyTitle: '最近追加はまだありません',
            emptyMessage: '作品が追加されると、ここに新着が並びます。',
            itemBuilder: (item) => _buildHomeMediaShelfCard(
              item: item,
              footerText:
                  '追加 ${_formatHomeDateTime(_homeAddedTimestamp(item))}',
              footerIcon: Icons.schedule_outlined,
              onTap: () => _openDetailFromHome(item),
            ),
          ),
          const SizedBox(height: 12),
          _buildHomeMediaShelf(
            title: '未読',
            subtitle: 'まだ開いていない PDF を最近追加の順に表示します。',
            items: _homeUnreadItems,
            emptyTitle: '未読の PDF はありません',
            emptyMessage: '未読の PDF があると、ここに表示されます。',
            itemBuilder: (item) => _buildHomeMediaShelfCard(
              item: item,
              footerText:
                  '追加 ${_formatHomeDateTime(_homeAddedTimestamp(item))}',
              footerIcon: Icons.mark_email_unread_outlined,
              badgeText: '未読',
              badgeIcon: Icons.mark_email_unread_outlined,
              badgeBackgroundColor: Theme.of(
                context,
              ).colorScheme.tertiaryContainer,
              badgeForegroundColor: Theme.of(
                context,
              ).colorScheme.onTertiaryContainer,
              onTap: () => _openDetailFromHome(item),
            ),
          ),
          const SizedBox(height: 12),
          _buildContinueReadingCard(),
          const SizedBox(height: 12),
          _buildHomeMediaShelf(
            title: '最近閲覧',
            subtitle: 'さっき見ていた作品へすぐ戻れます。',
            items: _homeRecentViewedItems,
            emptyTitle: '最近閲覧はまだありません',
            emptyMessage: '作品を開くと、ここに最近見たものが並びます。',
            itemBuilder: (item) {
              final activity = recentViewedEntries[item.id];
              final page = activity?.currentPage;
              final totalPages = activity?.totalPages;
              final pageText = page == null
                  ? null
                  : totalPages != null
                  ? 'p.$page / $totalPages'
                  : 'p.$page';
              final progressText = activity == null
                  ? null
                  : '${(activity.progress * 100).round()}%';
              return _buildHomeMediaShelfCard(
                item: item,
                footerText: pageText != null
                    ? '最終閲覧 ${_formatHomeDateTime(activity?.lastReadAt)} / $pageText / $progressText'
                    : '最終閲覧 ${_formatHomeDateTime(activity?.lastReadAt)}',
                footerIcon: Icons.history,
                badgeText: pageText,
                badgeIcon: pageText != null
                    ? Icons.auto_stories_outlined
                    : null,
                badgeBackgroundColor: Theme.of(
                  context,
                ).colorScheme.secondaryContainer,
                badgeForegroundColor: Theme.of(
                  context,
                ).colorScheme.onSecondaryContainer,
                onTap: () => _openDetailFromHome(
                  item,
                  initialPdfPage: item.kind == MediaKind.pdf && page != null
                      ? page
                      : 1,
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '登録フォルダ',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  if (_foldersRaw.isEmpty)
                    Text('登録フォルダがありません。「$_primaryAddActionLabel」から追加してください。')
                  else
                    ..._foldersRaw.map((raw) {
                      final isCurrent = raw == _currentFolderRaw;
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          isCurrent ? Icons.folder : Icons.folder_outlined,
                        ),
                        title: Text(
                          _folderLabel(raw),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          raw,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: '名前変更',
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () => _renameFolder(raw),
                            ),
                            IconButton(
                              tooltip: '削除',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _removeFolder(raw),
                            ),
                          ],
                        ),
                        onTap: () async {
                          await _switchFolder(raw);
                          _exitSelectMode();
                          setState(() => _page = _MainPage.gallery);
                        },
                      );
                    }),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHomeSearchGalleryBody() {
    if (_initializing) {
      return _buildRefreshableStatusBody(
        onRefresh: _handlePullToRefresh,
        child: _buildLoadingBody(
          title: '検索の準備中です',
          message: '設定とフォルダ情報を読み込んでいます。',
        ),
      );
    }

    if (_initializationErrorMessage != null) {
      return _buildRefreshableStatusBody(
        onRefresh: _handlePullToRefresh,
        child: _buildErrorBody(
          title: '初期化に失敗しました',
          message: _initializationErrorMessage!,
          onAction: _retryInitialization,
        ),
      );
    }

    if (!_repoCapabilities.canRecursiveSearch) {
      return _buildRefreshableStatusBody(
        onRefresh: _handlePullToRefresh,
        child: _buildEmptyBody(
          title: '全フォルダ検索は利用できません',
          message: 'このモードでは現在のフォルダ内の表示だけが利用できます。',
        ),
      );
    }

    if (!_homeSearching &&
        _homeSearchCorpusSignature.isEmpty &&
        _homeSearchErrorMessage == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _page != _MainPage.search || _homeSearching) {
          return;
        }
        _runHomeSearch(includeAllWhenEmpty: true);
      });
    }

    if (_homeSearching) {
      if (_homeSearchResults.isEmpty) {
        return _buildRefreshableStatusBody(
          onRefresh: _handlePullToRefresh,
          child: _buildLoadingBody(
            title: '詳細ブラウズを準備しています',
            message: '登録フォルダとタグ情報を読み込んでいます。',
          ),
        );
      }
    }

    if (_homeSearchErrorMessage != null) {
      return _buildDetailedBrowseResultsBody();
    }

    return _buildDetailedBrowseResultsBody();
  }

  // --------------------
  // --------------------
  String _basename(String raw) {
    String s = raw;
    if (s.startsWith('content://')) {
      try {
        final u = Uri.parse(s);
        final segs = u.pathSegments;

        String? encoded;
        final ti = segs.indexOf('tree');
        if (ti >= 0 && ti + 1 < segs.length) {
          encoded = segs[ti + 1];
        } else {
          final di = segs.indexOf('document');
          if (di >= 0 && di + 1 < segs.length) {
            encoded = segs[di + 1];
          }
        }
        if (encoded != null && encoded.isNotEmpty) {
          s = encoded;
        }
      } catch (_) {}
    }

    for (int i = 0; i < 2; i++) {
      if (!s.contains('%')) break;
      try {
        s = Uri.decodeComponent(s);
      } catch (_) {
        break;
      }
    }

    final colon = s.indexOf(':');
    if (colon >= 0) s = s.substring(colon + 1);

    s = s.replaceAll('\\', '/');
    final slash = s.lastIndexOf('/');
    if (slash >= 0) s = s.substring(slash + 1);

    return s.trim().isEmpty ? raw : s.trim();
  }

  String _displayTitleForItem(MediaItem item) {
    return ItemNameService.formatMediaTitle(item.displayName, kind: item.kind);
  }

  String _folderLabel(String raw) {
    final a = _folderAliases[raw];
    final sanitized = a == null
        ? null
        : _sanitizeFolderAlias(a, fallbackRaw: raw);
    if (sanitized != null && sanitized.trim().isNotEmpty) {
      return sanitized.trim();
    }
    return _basename(raw);
  }

  String? _sanitizeFolderAlias(String? alias, {required String fallbackRaw}) {
    if (alias == null) {
      return null;
    }
    final trimmed = alias.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    if (_looksLikeMojibake(trimmed)) {
      final fallback = _basename(fallbackRaw).trim();
      return fallback.isEmpty ? 'フォルダ' : fallback;
    }
    if (trimmed == 'Library') {
      return '保管庫';
    }
    return trimmed;
  }

  bool _looksLikeMojibake(String value) {
    const suspiciousCodePoints = <int>{
      0x7E5D,
      0x7E67,
      0x7E3A,
      0x8373,
      0x8B5B,
      0x900B,
      0x8B80,
      0x9A55,
      0x8711,
      0x96A7,
      0x908F,
      0x9666,
      0x9049,
      0x8389,
      0x8816,
      0x95BE,
      0x9AE2,
    };

    var suspiciousHits = 0;
    var halfwidthHits = 0;
    for (final rune in value.runes) {
      if (rune == 0xFFFD) {
        return true;
      }
      if (rune >= 0xFF61 && rune <= 0xFF9F) {
        halfwidthHits++;
      }
      if (suspiciousCodePoints.contains(rune)) {
        suspiciousHits++;
      }
    }

    return suspiciousHits >= 2 || halfwidthHits >= 2;
  }

  Future<void> _persistFolderAliases() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _PrefsKeys.folderAliasesJson,
      jsonEncode(_folderAliases),
    );
  }

  Future<void> _renameFolder(String raw) async {
    final controller = TextEditingController(
      text: _folderAliases[raw] ?? _basename(raw),
    );
    final result = await showControllerDialog<String>(
      context: context,
      autofocusBoundary: false,
      autofocusFirstFocusable: false,
      requestFocus: false,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('フォルダ名を変更'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '表示名（タイトル）',
              hintText: '例: 漫画 / 雑誌 / 保存用 など',
            ),
            onSubmitted: (_) => Navigator.of(ctx).pop(controller.text),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('キャンセル'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );

    if (result == null) return;

    final name = result.trim();
    setState(() {
      if (name.isEmpty) {
        _folderAliases.remove(raw);
      } else {
        _folderAliases[raw] = name;
      }
    });
    await _persistFolderAliases();
  }

  // --------------------
  // --------------------
  Future<void> _saveFitMode(ReaderFitMode mode) async {
    setState(() => _fitMode = mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_PrefsKeys.fitMode, mode.index);
  }

  Future<void> _saveTwoPage(bool value) async {
    setState(() => _twoPage = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_PrefsKeys.twoPage, value);
  }

  // --------------------
  // --------------------
  Future<void> _reloadFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    var favList = prefs.getStringList(_PrefsKeys.favorites) ?? const <String>[];
    final remoteFavorites = await widget.tagService
        .listRemoteFavoriteIds()
        .catchError((_) => null);
    if (remoteFavorites != null) {
      favList = remoteFavorites.toList(growable: false);
      await prefs.setStringList(_PrefsKeys.favorites, favList);
    }
    if (!mounted) return;
    setState(() => _favorites = favList.toSet());
    unawaited(_refreshResolvedFavoriteIds());
  }

  Future<void> _toggleFavorite(MediaItem item) async {
    final id = item.id;
    final lookupIds = await widget.tagService.favoriteLookupIdsForItem(item);
    final wasFavorite = lookupIds.any(_favorites.contains);

    final next = Set<String>.from(_favorites);
    if (wasFavorite) {
      next.removeAll(lookupIds);
    } else {
      next.add(id);
    }

    setState(() => _favorites = next);

    final remoteId = await widget.tagService
        .setRemoteFavorite(item, !wasFavorite)
        .catchError((_) => null);
    if (remoteId != null && remoteId != id) {
      if (next.remove(id)) {
        next.add(remoteId);
      }
      setState(() => _favorites = next);
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _PrefsKeys.favorites,
      next.toList(growable: false),
    );
    await _refreshAllFavoritesItems();
    await _refreshHomeShowcases();
  }

  Future<void> _refreshResolvedFavoriteIds() async {
    final items = <MediaItem>[
      ..._items,
      ..._favoriteItemsAll,
      ..._homeFavoriteShowcaseItems,
      ..._homeRecentAddedItems,
      ..._homeUnreadItems,
      ..._homeRecentViewedItems,
    ];
    if (items.isEmpty || _favorites.isEmpty) {
      if (!mounted) return;
      setState(() => _favoriteResolvedIds = <String>{});
      return;
    }
    final resolved = <String>{};
    for (final item in items) {
      final lookupIds = await widget.tagService.favoriteLookupIdsForItem(item);
      if (lookupIds.any(_favorites.contains)) {
        resolved.addAll(lookupIds);
      }
    }
    if (!mounted) return;
    setState(() => _favoriteResolvedIds = resolved);
  }

  Future<void> _openDetailFromHome(
    MediaItem item, {
    int initialPdfPage = 1,
  }) async {
    final folderRaw = item.folderRaw;

    List<MediaItem> folderItems =
        _folderItemsCache[folderRaw] ??
        (_currentFolderRaw == folderRaw ? _items : const <MediaItem>[]);

    if (folderItems.isEmpty) {
      try {
        folderItems = await widget.repo.listMedia(FolderHandle(folderRaw));
        _folderItemsCache[folderRaw] = folderItems;
      } catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('フォルダの読み込みに失敗しました: $error')));
        return;
      }
    }

    var idx = folderItems.indexWhere((entry) => entry.id == item.id);
    if (idx < 0) {
      try {
        folderItems = await widget.repo.listMedia(FolderHandle(folderRaw));
        _folderItemsCache[folderRaw] = folderItems;
        idx = folderItems.indexWhere((entry) => entry.id == item.id);
      } catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('フォルダ内容の再取得に失敗しました: $error')));
        return;
      }
    }

    if (idx < 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ファイルが見つかりません。移動または削除された可能性があります。')),
      );
      return;
    }

    if (!mounted) return;

    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ImageDetailPage(
          repo: widget.repo,
          tagService: widget.tagService,
          items: folderItems,
          initialIndex: idx,
          initialPdfPage: initialPdfPage,
        ),
      ),
    );

    if (changed == true) {
      _folderItemsCache.remove(folderRaw);
      _folderItemsCacheRecursive.remove(folderRaw);
      await _refreshVisibleContent();
      return;
    }

    await _refreshHomeShowcases();
  }

  bool _canDeleteItem(MediaItem item) {
    if (!_repoCapabilities.canDelete) {
      return false;
    }
    if (item.kind == MediaKind.folder && item.id.startsWith('content://')) {
      return false;
    }
    return true;
  }

  bool _canRenameItem(MediaItem item) {
    return widget.repo.capabilities.canRename;
  }

  Future<void> _replaceFavoriteId(String oldId, String newId) async {
    if (oldId == newId) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final next = (prefs.getStringList(_PrefsKeys.favorites) ?? const <String>[])
        .toSet();
    if (!next.remove(oldId)) {
      return;
    }
    next.add(newId);
    await prefs.setStringList(
      _PrefsKeys.favorites,
      next.toList(growable: false),
    );
    if (!mounted) {
      return;
    }
    setState(() => _favorites = next);
  }

  Future<void> _renameItemFromList(MediaItem item) async {
    if (!_canRenameItem(item)) {
      return;
    }

    final newBase = await showRenameItemDialog(context, item: item);
    if (newBase == null || newBase.isEmpty) {
      return;
    }

    try {
      final updated = await widget.repo.rename(item, newBase);
      String? metadataWarning;
      try {
        await widget.tagService.handleItemRenamed(item, updated);
      } catch (error) {
        metadataWarning = 'メタデータの更新に失敗しました: $error';
      }

      await _replaceFavoriteId(item.id, updated.id);
      await _refreshVisibleContent();
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('名前を変更しました: ${updated.displayName}')),
      );
      if (metadataWarning != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(metadataWarning)));
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('名前の変更に失敗しました: $error')));
    }
  }

  String _itemDeletionTypeLabel(MediaItem item) {
    switch (item.kind) {
      case MediaKind.pdf:
        return 'PDF';
      case MediaKind.image:
        return '画像';
      case MediaKind.folder:
        return 'フォルダ';
    }
  }

  Future<bool> _confirmItemDeletion(MediaItem item) async {
    final label = _itemDeletionTypeLabel(item);
    final result = await showControllerDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text('この$labelを削除しますか？'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('削除すると元に戻せません。'),
              const SizedBox(height: 12),
              Text(
                item.displayName,
                style: Theme.of(dialogContext).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                item.id,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('削除'),
            ),
          ],
        );
      },
    );
    return result == true;
  }

  Future<bool> _confirmItemsDeletion(List<MediaItem> items) async {
    if (items.isEmpty) {
      return false;
    }
    if (items.length == 1) {
      return _confirmItemDeletion(items.first);
    }

    final pdfCount = items.where((item) => item.kind == MediaKind.pdf).length;
    final imageCount = items
        .where((item) => item.kind == MediaKind.image)
        .length;
    final folderCount = items
        .where((item) => item.kind == MediaKind.folder)
        .length;
    final summary = <String>[
      if (pdfCount > 0) 'PDF: $pdfCount件',
      if (imageCount > 0) '画像: $imageCount件',
      if (folderCount > 0) 'フォルダ: $folderCount件',
    ].join('\n');

    final result = await showControllerDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text('選択中の${items.length}件を削除しますか？'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('削除すると元に戻せません。'),
              const SizedBox(height: 12),
              Text(summary),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('削除'),
            ),
          ],
        );
      },
    );
    return result == true;
  }

  Future<void> _removeFavoritesFromPrefs(Iterable<String> itemIds) async {
    final ids = itemIds.where((entry) => entry.trim().isNotEmpty).toSet();
    if (ids.isEmpty) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final next = (prefs.getStringList(_PrefsKeys.favorites) ?? const <String>[])
        .toSet();
    next.removeAll(ids);
    await prefs.setStringList(
      _PrefsKeys.favorites,
      next.toList(growable: false),
    );
    if (!mounted) return;
    setState(() => _favorites = next);
  }

  Future<List<MediaItem>> _collectMetadataDeletionTargets(
    List<MediaItem> items,
  ) async {
    final collected = <MediaItem>[];
    final seen = <String>{};

    void append(MediaItem item) {
      if (item.kind == MediaKind.folder) {
        return;
      }
      if (!seen.add(item.id)) {
        return;
      }
      collected.add(item);
    }

    for (final item in items) {
      if (item.kind == MediaKind.folder) {
        try {
          final descendants = await widget.repo.listMediaRecursiveFiles(
            FolderHandle(item.id),
          );
          for (final descendant in descendants) {
            append(descendant);
          }
        } catch (_) {}
        continue;
      }
      append(item);
    }
    return collected;
  }

  Future<void> _deleteItemsFromList(List<MediaItem> items) async {
    final targets = items.where(_canDeleteItem).toList(growable: false);
    if (targets.isEmpty) {
      return;
    }

    final confirmed = await _confirmItemsDeletion(targets);
    if (!confirmed || !mounted) {
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    final metadataTargets = await _collectMetadataDeletionTargets(targets);
    try {
      final deletedCount = await widget.repo.deleteItems(targets);
      if (deletedCount <= 0) {
        messenger.showSnackBar(const SnackBar(content: Text('削除に失敗しました')));
        return;
      }

      String? metadataWarning;
      try {
        if (metadataTargets.isNotEmpty) {
          await widget.tagService.handleDeletedItems(metadataTargets);
        }
      } catch (error) {
        metadataWarning = 'メタデータ削除に失敗しました: $error';
      }

      await _removeFavoritesFromPrefs([
        ...targets.map((item) => item.id),
        ...metadataTargets.map((item) => item.id),
      ]);
      if (!mounted) return;

      setState(() {
        _selectedIds.removeAll(targets.map((item) => item.id));
        if (_selectedIds.isEmpty) {
          _selectMode = false;
        }
      });

      await _refreshVisibleContent();
      if (!mounted) return;

      messenger.showSnackBar(
        SnackBar(
          content: Text(
            targets.length == 1
                ? '「${targets.first.displayName}」を削除しました'
                : '$deletedCount件を削除しました',
          ),
        ),
      );
      if (metadataWarning != null) {
        messenger.showSnackBar(SnackBar(content: Text(metadataWarning)));
      }
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('削除に失敗しました: $error')));
    }
  }

  Future<void> _deleteItemFromList(MediaItem item) async {
    await _deleteItemsFromList([item]);
  }

  String _folderLabelForItem(MediaItem item) {
    final folderRaw = item.folderRaw.trim();
    if (folderRaw.isNotEmpty) {
      for (final raw in _foldersRaw) {
        if (_sameFolderLocation(raw, folderRaw)) {
          return _folderLabel(raw);
        }
      }
      if (folderRaw.startsWith('content://') ||
          folderRaw.startsWith('remote://')) {
        return _folderLabel(folderRaw);
      }
    }

    final itemNorm = _normalizePath(item.id);

    String? bestMatchRaw;
    var bestLen = -1;

    for (final raw in _foldersRaw) {
      final folderNorm = _normalizePath(raw);

      final ok = itemNorm == folderNorm || itemNorm.startsWith('$folderNorm\\');
      if (!ok) continue;

      if (folderNorm.length > bestLen) {
        bestLen = folderNorm.length;
        bestMatchRaw = raw;
      }
    }

    if (bestMatchRaw != null) {
      return _folderLabel(bestMatchRaw);
    }

    final parentRaw = folderRaw.isNotEmpty
        ? folderRaw
        : _parentDirOfFullPath(item.id);
    return _basename(parentRaw);
  }

  String _normalizePath(String p) {
    var s = p.replaceAll('/', '\\');
    while (s.endsWith('\\')) {
      s = s.substring(0, s.length - 1);
    }
    return s.toLowerCase();
  }

  bool _sameFolderLocation(String left, String right) {
    final lhs = left.trim();
    final rhs = right.trim();
    if (lhs.isEmpty || rhs.isEmpty) {
      return false;
    }
    if (lhs.startsWith('content://') || rhs.startsWith('content://')) {
      return lhs == rhs;
    }
    return _normalizePath(lhs) == _normalizePath(rhs);
  }

  // --------------------
  // --------------------
  Future<void> _saveLastFolder(FolderHandle folder) async {
    if (widget.repo.isRemoteMode) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_PrefsKeys.lastFolderRaw, folder.raw);
  }

  Future<void> _loadFolder(
    FolderHandle folder, {
    required bool saveAsLast,
    int pageIndex = 0,
  }) async {
    _invalidateGallerySearchCache();
    setState(() {
      _thumbsEnabled = false;
      _folder = folder;
      _loading = true;
      _items = const [];
      _galleryLoadErrorMessage = null;
      _loadProcessed = 0;
      _loadTotal = 0;
      _galleryPageIndex = pageIndex;
      _galleryTotal = 0;
    });
    _folderPreviewInFlight.clear();

    if (saveAsLast) {
      await _saveLastFolder(folder);
    }

    try {
      final offset = pageIndex * _pageSize;
      final res = await widget.repo.listMediaPage(
        folder,
        offset: offset,
        limit: _pageSize,
        onProgress: (p, t) {
          if (!mounted) return;
          setState(() {
            _loadProcessed = p;
            _loadTotal = t;
          });
        },
      );
      if (!mounted) return;

      final maxPageIndex = res.total <= 0 ? 0 : (res.total - 1) ~/ _pageSize;
      if (res.total > 0 && pageIndex > maxPageIndex) {
        await _loadFolder(folder, saveAsLast: false, pageIndex: maxPageIndex);
        return;
      }

      setState(() {
        _galleryTotal = res.total;
        _items = res.items;
        _loading = false;
        _galleryLoadErrorMessage = null;
      });

      widget.tagService.rememberItems(res.items);
      unawaited(_refreshCurrentPageTags(res.items));

      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (!mounted) return;
        setState(() => _thumbsEnabled = true);
      });

      _folderItemsCache[folder.raw] = _items;
      await _refreshAllFavoritesItems();
      unawaited(_refreshHomeShowcases());
      unawaited(_ensureGallerySearchCacheLoaded());
      if (_query.trim().isNotEmpty) {
        _setGallerySearchQuery(
          _query,
          enableSuggestions: _gallerySearchSuggestionsEnabled,
        );
      }
    } catch (e, st) {
      _logUiError('load-folder', e, st);
      final message = 'フォルダの読み込みに失敗しました: $e';
      if (!mounted) return;
      setState(() {
        _loading = false;
        _galleryLoadErrorMessage = message;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _loadGalleryPage(int pageIndex) async {
    final folder = _folder;
    if (folder == null) return;

    final offset = pageIndex * _pageSize;

    setState(() {
      _thumbsEnabled = false;
      _loading = true;
      _items = const [];
      _galleryLoadErrorMessage = null;
      _loadProcessed = 0;
      _loadTotal = 0;
    });

    try {
      final res = await widget.repo.listMediaPage(
        folder,
        offset: offset,
        limit: _pageSize,
        onProgress: (p, t) {
          if (!mounted) return;
          setState(() {
            _loadProcessed = p;
            _loadTotal = t;
          });
        },
      );
      if (!mounted) return;

      final maxPageIndex = res.total <= 0 ? 0 : (res.total - 1) ~/ _pageSize;
      if (res.total > 0 && pageIndex > maxPageIndex) {
        await _loadGalleryPage(maxPageIndex);
        return;
      }

      setState(() {
        _galleryPageIndex = pageIndex;
        _galleryTotal = res.total;
        _items = res.items;
        _loading = false;
        _galleryLoadErrorMessage = null;
      });

      widget.tagService.rememberItems(res.items);
      unawaited(_refreshCurrentPageTags(res.items));

      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (!mounted) return;
        setState(() => _thumbsEnabled = true);
      });
      if (_query.trim().isNotEmpty) {
        unawaited(_ensureGallerySearchCacheLoaded());
      }
    } catch (e, st) {
      _logUiError('load-gallery-page', e, st);
      final message = 'ページの読み込みに失敗しました: $e';
      if (!mounted) return;
      setState(() {
        _loading = false;
        _galleryLoadErrorMessage = message;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _persistFolders() async {
    if (widget.repo.isRemoteMode) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_PrefsKeys.folders, _foldersRaw);
    if (_currentFolderRaw == null) {
      await prefs.remove(_PrefsKeys.currentFolder);
    } else {
      await prefs.setString(_PrefsKeys.currentFolder, _currentFolderRaw!);
    }
  }

  Future<void> _addFolder() async {
    if (_repoCapabilities.canImportToHost) {
      await _importToHostWithTags();
      return;
    }
    if (!_repoCapabilities.canAddLocalFolder) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('このモードではフォルダ追加は未対応です')));
      return;
    }

    final folder = await widget.repo.pickFolder();
    if (folder == null) return;
    final raw = folder.raw;
    final next = List<String>.from(_foldersRaw);
    _dirStack.clear();
    if (!next.contains(raw)) {
      next.add(raw);
    }
    setState(() {
      _foldersRaw = next.toList(growable: false);
      _currentFolderRaw = raw;
    });
    await _persistFolders();
    await _loadFolder(folder, saveAsLast: false);
  }

  Future<void> _importToHostWithTags() async {
    if (!_repoCapabilities.canImportToHost) {
      return;
    }

    final result = await ImportToHostDialog.show(
      context,
      tagService: widget.tagService,
      initialSelection: const ImportToHostSelection(
        sourceKind: ImportSourceKind.files,
        items: <MediaItem>[],
      ),
      onPickSelection: _pickHostImportSelectionForDialog,
      supportsHostPdfConversion: true,
    );
    if (result == null) {
      return;
    }
    final selection = result.selection;
    final request = result.request;

    final progress = ValueNotifier<MediaTransferProgress?>(null);
    var dialogShown = false;
    final dialogHandle = _RouteBoundDialogHandle();

    try {
      final lib = await widget.repo.getAppLibraryFolder();
      final libRaw = lib.raw;
      if (!_foldersRaw.contains(libRaw)) {
        setState(() {
          _foldersRaw = <String>[libRaw, ..._foldersRaw];
        });
      }

      if (!mounted) return;

      dialogShown = true;
      unawaited(
        showControllerDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => dialogHandle.bind(
            dialogContext,
            AlertDialog(
              title: const Text('ホストへ取り込み中...'),
              content: ValueListenableBuilder<MediaTransferProgress?>(
                valueListenable: progress,
                builder: (context, value, _) {
                  final fraction = value?.fraction;
                  final completed = value?.completedFiles ?? 0;
                  final total = value?.totalFiles ?? 0;
                  final statusLabel = value?.statusLabel?.trim();
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      LinearProgressIndicator(
                        value: fraction == null || total == 0 ? null : fraction,
                      ),
                      const SizedBox(height: 12),
                      Text(total == 0 ? '準備中...' : '$completed / $total'),
                      if (statusLabel != null && statusLabel.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(statusLabel),
                      ],
                      if (value?.currentFileName != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          value!.currentFileName!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );

      final importedCount = await widget.repo.importItemsIntoFolder(
        lib,
        selection.items,
        importMetadata: request.metadata,
        skipIfExists: request.skipIfExists,
        onProgress: (next) => progress.value = next,
      );
      if (!mounted) return;

      if (importedCount <= 0) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('取り込み対象がありませんでした')));
        return;
      }

      String? refreshWarning;
      try {
        _folderItemsCache.clear();
        _folderItemsCacheRecursive.clear();
        _dirStack.clear();

        setState(() {
          _currentFolderRaw = libRaw;
          _folder = lib;
          _page = _MainPage.gallery;
        });
        await _persistFolders();
        await _loadFolder(lib, saveAsLast: false);

        if (!mounted) return;
        await _refreshDetailedBrowseIfNeeded();
        await _refreshCurrentPageTags();
        await _reloadArtistTagMasters();
        await _refreshArtistTagCounts();
      } catch (error, stackTrace) {
        _logUiError('post-import-refresh', error, stackTrace);
        refreshWarning = '一覧の更新に失敗しました: $error';
      }

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('ホストへ取り込み完了: $importedCount 件')));
      if (refreshWarning != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(refreshWarning)));
      }
    } catch (e, st) {
      _logUiError('host-import', e, st);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('ホスト取り込みに失敗しました: $e')));
    } finally {
      progress.dispose();
      await _cleanupImportSelectionPaths(selection.cleanupPaths);
      if (dialogShown) {
        dialogHandle.close();
      }
    }
  }

  Future<ImportSourceKind?> _pickImportSourceKind() async {
    return showControllerModalBottomSheet<ImportSourceKind>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.upload_file_outlined),
                title: const Text('複数ファイル'),
                subtitle: const Text('PDF や画像を複数選んで取り込みます'),
                onTap: () => Navigator.of(context).pop(ImportSourceKind.files),
              ),
              ListTile(
                leading: const Icon(Icons.folder_open_outlined),
                title: const Text('画像フォルダ'),
                subtitle: const Text('フォルダを選び、中の画像や PDF をまとめて取り込みます'),
                onTap: () => Navigator.of(context).pop(ImportSourceKind.folder),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<_PreparedImportSelection?> _pickHostImportSelection(
    ImportSourceKind sourceKind,
  ) async {
    switch (sourceKind) {
      case ImportSourceKind.files:
        final items = await widget.repo.pickExternalMediaFiles(
          allowMultiple: true,
          includeImages: true,
          includePdf: true,
        );
        if (items.isEmpty) {
          return null;
        }
        return _PreparedImportSelection(sourceKind: sourceKind, items: items);
      case ImportSourceKind.folder:
        final progress = ValueNotifier<MediaTransferProgress?>(
          const MediaTransferProgress(
            sentBytes: 0,
            totalBytes: 0,
            completedFiles: 0,
            totalFiles: 0,
            statusLabel: '取り込み元フォルダを選択しています',
          ),
        );
        var dialogShown = false;
        final dialogHandle = _RouteBoundDialogHandle();
        try {
          void ensureDialogShown() {
            if (dialogShown || !mounted) {
              return;
            }
            dialogShown = true;
            unawaited(
              showControllerDialog<void>(
                context: context,
                barrierDismissible: false,
                builder: (dialogContext) => dialogHandle.bind(
                  dialogContext,
                  AlertDialog(
                    title: const Text('取り込み元を確認中...'),
                    content: ValueListenableBuilder<MediaTransferProgress?>(
                      valueListenable: progress,
                      builder: (context, value, _) {
                        final completed = value?.completedFiles ?? 0;
                        final total = value?.totalFiles ?? 0;
                        final statusLabel = value?.statusLabel?.trim();
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const LinearProgressIndicator(),
                            const SizedBox(height: 12),
                            if (total > 0)
                              Text('$completed / $total')
                            else
                              const Text('準備中...'),
                            if (statusLabel != null &&
                                statusLabel.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(statusLabel),
                            ],
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            );
          }

          ensureDialogShown();
          await Future<void>.delayed(Duration.zero);
          final pickedItems = await widget.repo.pickExternalMediaFolderItems(
            onProgress: (processed, total) {
              ensureDialogShown();
              progress.value = MediaTransferProgress(
                sentBytes: 0,
                totalBytes: 0,
                completedFiles: processed,
                totalFiles: total,
                statusLabel: '取り込み元フォルダを走査しています',
              );
            },
          );
          if (pickedItems.isEmpty) {
            return null;
          }
          return _PreparedImportSelection(
            sourceKind: sourceKind,
            items: pickedItems,
          );
        } finally {
          progress.dispose();
          if (dialogShown) {
            dialogHandle.close();
          }
        }
    }
  }

  Future<ImportToHostSelection?> _pickHostImportSelectionForDialog(
    ImportSourceKind sourceKind,
  ) async {
    final selection = await _pickHostImportSelection(sourceKind);
    if (selection == null) {
      return null;
    }
    return ImportToHostSelection(
      sourceKind: selection.sourceKind,
      items: selection.items,
      cleanupPaths: selection.cleanupPaths,
    );
  }

  Widget _buildGallerySeriesFilterRow(List<_FolderSeriesFilterChip> chips) {
    if (chips.isEmpty) {
      return SizedBox(
        height: 36,
        child: Row(
          children: const [
            Text('シリーズ'),
            SizedBox(width: 8),
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        ),
      );
    }

    final activeSeriesKey = _activeGallerySeriesFilterKey();
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          const Text('シリーズ'),
          const SizedBox(width: 8),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: chips.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final chip = chips[index];
                final selected = activeSeriesKey == chip.name.toLowerCase();
                final label = chip.count > 1
                    ? '${chip.name} (${chip.count})'
                    : chip.name;
                return ChoiceChip(
                  label: Text(label),
                  selected: selected,
                  onSelected: (_) => _toggleGallerySeriesFilter(chip.name),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _cleanupImportSelectionPaths(
    Iterable<String> cleanupPaths,
  ) async {
    for (final path in cleanupPaths) {
      final trimmed = path.trim();
      if (trimmed.isEmpty || trimmed.startsWith('content://')) {
        continue;
      }
      try {
        final file = File(trimmed);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (error) {
        debugPrint(
          '[host-import] temp cleanup failed path=$trimmed error=$error',
        );
      }
    }
  }

  Future<void> _cleanupPreparedImportSelection(
    _PreparedImportSelection selection,
  ) async {
    await _cleanupImportSelectionPaths(selection.cleanupPaths);
  }

  Future<void> _switchFolder(String raw) async {
    if (_currentFolderRaw == raw) return;
    _dirStack.clear();

    setState(() {
      _currentFolderRaw = raw;
    });

    await _persistFolders();
    await _loadFolder(FolderHandle(raw), saveAsLast: false);
  }

  Future<void> _removeFolder(String raw) async {
    final action = await _confirmRegisteredFolderRemoval(raw);
    if (action == null) {
      return;
    }

    if (action == _RegisteredFolderRemovalAction.deleteFiles) {
      final existingItems = await _loadFolderItemsForDeletion(raw);
      final deleted = await widget.repo.deleteItem(
        MediaItem(
          id: raw,
          displayName: _folderLabel(raw),
          kind: MediaKind.folder,
          folderRaw: _registeredFolderParentRaw(raw),
        ),
      );
      if (!mounted) return;
      if (!deleted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('フォルダ本体の削除に失敗しました')));
        return;
      }
      if (existingItems.isNotEmpty) {
        try {
          await widget.tagService.handleDeletedItems(existingItems);
        } catch (_) {}
      }
    }

    await _removeFolderRegistration(raw);
    if (!mounted) return;
    final message = action == _RegisteredFolderRemovalAction.deleteFiles
        ? '登録フォルダと実ファイルを削除しました'
        : '登録フォルダを一覧から削除しました';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _removeFolderRegistration(String raw) async {
    final next = List<String>.from(_foldersRaw)..remove(raw);
    _dirStack.clear();

    String? nextCurrent = _currentFolderRaw;
    if (nextCurrent == raw) {
      nextCurrent = next.isNotEmpty ? next.first : null;
    }

    setState(() {
      _foldersRaw = next.toList(growable: false);
      _currentFolderRaw = nextCurrent;
      _folder = nextCurrent == null ? null : FolderHandle(nextCurrent);
      _items = const [];
      _galleryLoadErrorMessage = null;
    });

    _folderItemsCache.remove(raw);
    await _refreshAllFavoritesItems();
    await _refreshDetailedBrowseIfNeeded();
    await _refreshCurrentPageTags();
    await _refreshArtistTagCounts();

    await _persistFolders();

    if (nextCurrent == null) return;
    await _loadFolder(FolderHandle(nextCurrent), saveAsLast: false);
  }

  Future<_RegisteredFolderRemovalAction?> _confirmRegisteredFolderRemoval(
    String raw,
  ) {
    final canHardDelete = _canHardDeleteRegisteredFolder(raw);
    return showControllerDialog<_RegisteredFolderRemovalAction>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('登録フォルダを削除'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('本当に削除しますか？'),
              const SizedBox(height: 8),
              const Text('登録のみ解除するのか、フォルダ本体と実ファイルまで削除するのかを確認してから実行してください。'),
              const SizedBox(height: 12),
              Text(
                _folderLabel(raw),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                raw,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (!canHardDelete) ...[
                const SizedBox(height: 12),
                const Text('このフォルダでは実ファイル削除は使えないため、登録解除のみ行えます。'),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(
                context,
                _RegisteredFolderRemovalAction.unregisterOnly,
              ),
              child: const Text('登録のみ削除'),
            ),
            if (canHardDelete)
              FilledButton(
                onPressed: () => Navigator.pop(
                  context,
                  _RegisteredFolderRemovalAction.deleteFiles,
                ),
                child: const Text('実ファイルも削除'),
              ),
          ],
        );
      },
    );
  }

  bool _canHardDeleteRegisteredFolder(String raw) {
    if (widget.repo.isRemoteMode || !_repoCapabilities.canDelete) {
      return false;
    }
    if (raw.startsWith('content://') || raw.startsWith('remote://')) {
      return false;
    }
    return Directory(raw).existsSync();
  }

  Future<List<MediaItem>> _loadFolderItemsForDeletion(String raw) async {
    try {
      return await widget.repo.listMediaRecursiveFiles(FolderHandle(raw));
    } catch (_) {
      return const <MediaItem>[];
    }
  }

  String _registeredFolderParentRaw(String raw) {
    if (raw.startsWith('content://') || raw.startsWith('remote://')) {
      return raw;
    }
    try {
      return Directory(raw).parent.path;
    } catch (_) {
      return raw;
    }
  }

  FolderHandle? _activeImportFolder() {
    final activeFolder = _folder;
    if (activeFolder != null) {
      return activeFolder;
    }
    final currentFolderRaw = _currentFolderRaw?.trim();
    if (currentFolderRaw == null || currentFolderRaw.isEmpty) {
      return null;
    }
    return FolderHandle(currentFolderRaw);
  }

  Future<void> _activateImportedFolder(FolderHandle folder) async {
    _dirStack.clear();
    setState(() {
      if (_foldersRaw.contains(folder.raw)) {
        _currentFolderRaw = folder.raw;
      }
      _folder = folder;
      _page = _MainPage.gallery;
    });
    await _persistFolders();
  }

  bool get _usesAndroidImportPreparationFlow =>
      Platform.isAndroid && !_repoCapabilities.canImportToHost;

  Future<List<MediaItem>> _pickAndroidFolderImportItems() async {
    final progress = ValueNotifier<MediaTransferProgress?>(
      const MediaTransferProgress(
        sentBytes: 0,
        totalBytes: 0,
        completedFiles: 0,
        totalFiles: 0,
        statusLabel: 'Scanning folder...',
      ),
    );
    var dialogShown = false;
    final dialogHandle = _RouteBoundDialogHandle();
    try {
      void ensureDialogShown() {
        if (dialogShown || !mounted) {
          return;
        }
        dialogShown = true;
        unawaited(
          showControllerDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (dialogContext) => dialogHandle.bind(
              dialogContext,
              AlertDialog(
                title: const Text('Preparing Folder Import...'),
                content: ValueListenableBuilder<MediaTransferProgress?>(
                  valueListenable: progress,
                  builder: (context, value, _) {
                    final completed = value?.completedFiles ?? 0;
                    final total = value?.totalFiles ?? 0;
                    final statusLabel = value?.statusLabel?.trim();
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const LinearProgressIndicator(),
                        const SizedBox(height: 12),
                        Text(total > 0 ? '$completed / $total' : 'Loading...'),
                        if (statusLabel != null && statusLabel.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(statusLabel),
                        ],
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        );
      }

      ensureDialogShown();
      await Future<void>.delayed(Duration.zero);
      final pickedItems = await widget.repo.pickExternalMediaFolderItems(
        onProgress: (processed, total) {
          ensureDialogShown();
          progress.value = MediaTransferProgress(
            sentBytes: 0,
            totalBytes: 0,
            completedFiles: processed,
            totalFiles: total,
            statusLabel: 'Scanning folder...',
          );
        },
      );
      return pickedItems;
    } finally {
      progress.dispose();
      if (dialogShown) {
        dialogHandle.close();
      }
    }
  }

  Future<_AndroidImportConversionChoice?> _pickAndroidImportConversionChoice(
    List<MediaItem> items,
  ) async {
    final imageCount = items
        .where((item) => item.kind == MediaKind.image)
        .length;
    if (imageCount < 2 ||
        !ImportPdfConversionService.canConvertItemsToPdf(items)) {
      return _AndroidImportConversionChoice.keepImages;
    }

    return showControllerModalBottomSheet<_AndroidImportConversionChoice>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text('Choose Import Format'),
                subtitle: Text(
                  '$imageCount images were detected. Keep them as images or merge them into one PDF.',
                ),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Import Images'),
                subtitle: Text('Keep $imageCount image files.'),
                onTap: () => Navigator.of(
                  context,
                ).pop(_AndroidImportConversionChoice.keepImages),
              ),
              ListTile(
                leading: const Icon(Icons.picture_as_pdf_outlined),
                title: const Text('Merge into PDF'),
                subtitle: const Text('Create one PDF before importing.'),
                onTap: () => Navigator.of(
                  context,
                ).pop(_AndroidImportConversionChoice.mergeToPdf),
              ),
              ListTile(
                leading: const Icon(Icons.close),
                title: const Text('Cancel'),
                onTap: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<_PreparedImportSelection?> _prepareAndroidImportSelection({
    required ImportSourceKind sourceKind,
    required List<MediaItem> items,
  }) async {
    if (items.isEmpty) {
      return null;
    }

    final choice = await _pickAndroidImportConversionChoice(items);
    if (choice == null) {
      return null;
    }
    if (choice != _AndroidImportConversionChoice.mergeToPdf) {
      return _PreparedImportSelection(sourceKind: sourceKind, items: items);
    }

    String? libraryRootRaw;
    try {
      libraryRootRaw = (await widget.repo.getAppLibraryFolder()).raw;
    } catch (_) {}

    final progress = ValueNotifier<MediaTransferProgress?>(
      const MediaTransferProgress(
        sentBytes: 0,
        totalBytes: 0,
        completedFiles: 0,
        totalFiles: 0,
        statusLabel: 'Building PDF...',
      ),
    );
    var dialogShown = false;
    final dialogHandle = _RouteBoundDialogHandle();
    try {
      if (!mounted) return null;

      dialogShown = true;
      unawaited(
        showControllerDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => dialogHandle.bind(
            dialogContext,
            AlertDialog(
              title: const Text('Building PDF...'),
              content: ValueListenableBuilder<MediaTransferProgress?>(
                valueListenable: progress,
                builder: (context, value, _) {
                  final completed = value?.completedFiles ?? 0;
                  final total = value?.totalFiles ?? 0;
                  final fraction = total == 0 ? null : completed / total;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      LinearProgressIndicator(value: fraction),
                      const SizedBox(height: 12),
                      Text(total > 0 ? '$completed / $total' : 'Loading...'),
                      if (value?.statusLabel != null &&
                          value!.statusLabel!.trim().isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(value.statusLabel!.trim()),
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );

      final converted = await ImportPdfConversionService.prepareForImport(
        repo: widget.repo,
        items: items,
        convertToPdf: true,
        libraryRootRaw: libraryRootRaw,
        onPdfProgress: (done, total) {
          progress.value = MediaTransferProgress(
            sentBytes: 0,
            totalBytes: 0,
            completedFiles: done,
            totalFiles: total,
            statusLabel: 'Building PDF...',
          );
        },
      );
      return _PreparedImportSelection(
        sourceKind: sourceKind,
        items: converted.items,
        cleanupPaths: converted.cleanupPaths,
      );
    } finally {
      progress.dispose();
      if (dialogShown) {
        dialogHandle.close();
      }
    }
  }

  Future<_PreparedImportSelection?> _pickAndroidImportSelection() async {
    final sourceKind = await _pickImportSourceKind();
    if (sourceKind == null) {
      return null;
    }

    final items = switch (sourceKind) {
      ImportSourceKind.files => await widget.repo.pickExternalMediaFiles(
        allowMultiple: true,
        includeImages: true,
        includePdf: true,
      ),
      ImportSourceKind.folder => await _pickAndroidFolderImportItems(),
    };
    if (items.isEmpty) {
      return null;
    }

    return _prepareAndroidImportSelection(sourceKind: sourceKind, items: items);
  }

  Future<void> _importToCurrentFolder() async {
    if (_repoCapabilities.canImportToHost) {
      await _importToHostWithTags();
      return;
    }
    if (!_repoCapabilities.canUpload) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('このモードでは取り込みは未対応です')));
      return;
    }
    final folder = _activeImportFolder();
    if (folder == null) return;
    _PreparedImportSelection? selection;
    if (_usesAndroidImportPreparationFlow) {
      selection = await _pickAndroidImportSelection();
      if (selection == null) {
        return;
      }
    }
    final progress = ValueNotifier<MediaTransferProgress?>(null);
    var dialogShown = false;
    final dialogHandle = _RouteBoundDialogHandle();
    try {
      if (!mounted) return;

      dialogShown = true;
      unawaited(
        showControllerDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => dialogHandle.bind(
            dialogContext,
            AlertDialog(
              title: Text(widget.repo.isRemoteMode ? 'アップロード中...' : '取り込み中...'),
              content: ValueListenableBuilder<MediaTransferProgress?>(
                valueListenable: progress,
                builder: (context, value, _) {
                  final fraction = value?.fraction;
                  final completed = value?.completedFiles ?? 0;
                  final total = value?.totalFiles ?? 0;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      LinearProgressIndicator(
                        value: fraction == null || total == 0 ? null : fraction,
                      ),
                      const SizedBox(height: 12),
                      Text(total == 0 ? '準備中...' : '$completed / $total'),
                      if (value?.currentFileName != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          value!.currentFileName!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );
      final count = selection == null
          ? await widget.repo.importIntoFolder(
              folder,
              onProgress: (next) => progress.value = next,
            )
          : await widget.repo.importItemsIntoFolder(
              folder,
              selection.items,
              skipIfExists: true,
              onProgress: (next) => progress.value = next,
            );
      if (!mounted) return;

      if (count > 0) {
        try {
          await widget.tagService.requestRescan();
        } catch (_) {}
        await _loadFolder(folder, saveAsLast: false);
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('取り込み完了: $count 件')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('取り込みに失敗しました: $e')));
    } finally {
      progress.dispose();
      if (selection != null) {
        await _cleanupPreparedImportSelection(selection);
      }
      if (dialogShown) {
        dialogHandle.close();
      }
    }
  }

  Future<void> _importToLibraryAndTag() async {
    if (_repoCapabilities.canImportToHost) {
      await _importToHostWithTags();
      return;
    }
    if (!_repoCapabilities.canUpload) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('このモードでは取り込みは未対応です')));
      return;
    }
    final progress = ValueNotifier<MediaTransferProgress?>(null);
    var dialogShown = false;
    final dialogHandle = _RouteBoundDialogHandle();
    _PreparedImportSelection? selection;
    try {
      final lib = await widget.repo.getAppLibraryFolder();
      final libRaw = lib.raw;

      if (!_foldersRaw.contains(libRaw)) {
        setState(() {
          _foldersRaw = <String>[libRaw, ..._foldersRaw];
        });
        await _persistFolders();
      }

      final before = await widget.repo.listMedia(lib);
      final beforeIds = before.map((e) => e.id).toSet();
      if (_usesAndroidImportPreparationFlow) {
        selection = await _pickAndroidImportSelection();
        if (selection == null) {
          return;
        }
      }

      if (!mounted) return;

      dialogShown = true;
      unawaited(
        showControllerDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => dialogHandle.bind(
            dialogContext,
            AlertDialog(
              title: Text(widget.repo.isRemoteMode ? 'アップロード中...' : '取り込み中...'),
              content: ValueListenableBuilder<MediaTransferProgress?>(
                valueListenable: progress,
                builder: (context, value, _) {
                  final fraction = value?.fraction;
                  final completed = value?.completedFiles ?? 0;
                  final total = value?.totalFiles ?? 0;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      LinearProgressIndicator(
                        value: fraction == null || total == 0 ? null : fraction,
                      ),
                      const SizedBox(height: 12),
                      Text(total == 0 ? '準備中...' : '$completed / $total'),
                      if (value?.currentFileName != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          value!.currentFileName!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );

      final importedCount = selection == null
          ? await widget.repo.importIntoFolder(
              lib,
              onProgress: (next) => progress.value = next,
            )
          : await widget.repo.importItemsIntoFolder(
              lib,
              selection.items,
              skipIfExists: true,
              onProgress: (next) => progress.value = next,
            );
      if (!mounted) return;

      if (importedCount <= 0) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('取り込み対象がありませんでした')));
        return;
      }

      try {
        await widget.tagService.requestRescan();
      } catch (_) {}

      final after = await widget.repo.listMedia(lib);
      final newItems = after
          .where((e) => e.kind != MediaKind.folder && !beforeIds.contains(e.id))
          .toList(growable: false);

      _dirStack.clear();
      setState(() {
        _currentFolderRaw = libRaw;
        _page = _MainPage.gallery;
      });
      await _persistFolders();

      await _loadFolder(lib, saveAsLast: false);
      if (!mounted) return;

      if (newItems.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('ライブラリへ取り込み: $importedCount 件（差分なし）')),
        );
        return;
      }

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TagAssignAfterImportPage(
            items: newItems,
            tagService: widget.tagService,
          ),
        ),
      );

      if (!mounted) return;

      await _refreshDetailedBrowseIfNeeded();
      await _refreshCurrentPageTags();
      await _refreshArtistTagCounts();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'ライブラリへ取り込み: $importedCount 件・タグ付け対象: ${newItems.length} 件',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('ライブラリ取り込みに失敗しました: $e')));
    } finally {
      progress.dispose();
      if (selection != null) {
        await _cleanupPreparedImportSelection(selection);
      }
      if (dialogShown) {
        dialogHandle.close();
      }
    }
  }

  Future<void> _importUrlToCurrentFolder() async {
    if (!widget.repo.canImportFromUrl) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('このモードでは URL 取り込みは未対応です')));
      return;
    }
    final folder = _activeImportFolder();
    if (folder == null) return;

    await _runUrlImport(
      folder: folder,
      dialogTitle: widget.repo.isRemoteMode
          ? 'URLからホストへ取り込み'
          : 'URLから現在フォルダへ取り込み',
      dialogDescription: widget.repo.isRemoteMode
          ? 'Kemono / Coomer / Hitomi の URL を複数入力するか、お気に入り取得条件を指定して取り込みます。hitomi / kemono や作者階層はタグ化して、メディアは現在フォルダ直下へ整理します。'
          : Platform.isAndroid
          ? '直接メディア URL を複数入力して現在のフォルダへ保存します。Android のスタンドアロン動作では favorites 取得や Cookie 前提のサイト取り込みは未対応です。'
          : 'Kemono / Coomer / Hitomi の URL を複数入力するか、お気に入り取得条件を指定して現在のフォルダ配下へ保存します。',
      progressTitle: 'URL をダウンロードして取り込み中...',
      successLabel: 'URL取り込み',
    );
  }

  Future<void> _handlePendingSharedImport(_PendingSharedImport pending) async {
    if (pending.hasMediaItems) {
      await _handlePendingSharedMediaImport(pending.mediaItems);
      return;
    }
    if (pending.hasUrls) {
      await _handlePendingSharedUrlImport(pending.urls);
    }
  }

  Future<void> _handlePendingSharedMediaImport(
    List<MediaItem> mediaItems,
  ) async {
    if (!_repoCapabilities.canUpload) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('このモードでは共有ファイルの取り込みは未対応です')));
      return;
    }

    final target = await _pickSharedImportTarget(
      title: '共有されたファイルを取り込む',
      subtitle: '${mediaItems.length} 件の PDF / 画像の保存先を選んでください。',
      currentFolderSubtitle: '表示中のフォルダへ取り込みます',
      librarySubtitle: 'ライブラリへ取り込みます',
    );
    if (target == null) {
      return;
    }

    final selection = Platform.isAndroid
        ? await _prepareAndroidImportSelection(
            sourceKind: ImportSourceKind.files,
            items: mediaItems,
          )
        : _PreparedImportSelection(
            sourceKind: ImportSourceKind.files,
            items: mediaItems,
          );
    if (selection == null) {
      return;
    }

    await _runSharedMediaImport(selection: selection, target: target);
  }

  Future<void> _runSharedMediaImport({
    required _PreparedImportSelection selection,
    required _SharedUrlImportTarget target,
  }) async {
    final progress = ValueNotifier<MediaTransferProgress?>(
      MediaTransferProgress(
        sentBytes: 0,
        totalBytes: 0,
        completedFiles: 0,
        totalFiles: selection.items.length,
        statusLabel: '共有ファイルを取り込み中...',
      ),
    );
    var dialogShown = false;
    final dialogHandle = _RouteBoundDialogHandle();
    try {
      dialogShown = true;
      unawaited(
        showControllerDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => dialogHandle.bind(
            dialogContext,
            AlertDialog(
              title: const Text('共有ファイルを取り込み中...'),
              content: ValueListenableBuilder<MediaTransferProgress?>(
                valueListenable: progress,
                builder: (context, value, _) {
                  final fraction = value?.fraction;
                  final completed = value?.completedFiles ?? 0;
                  final total = value?.totalFiles ?? selection.items.length;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      LinearProgressIndicator(
                        value: fraction == null || total == 0 ? null : fraction,
                      ),
                      const SizedBox(height: 12),
                      Text(total == 0 ? '準備中...' : '$completed / $total'),
                      if (value?.currentFileName != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          value!.currentFileName!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );

      final importedCount = await widget.repo.importItemsIntoFolder(
        target.folder,
        selection.items,
        skipIfExists: true,
        onProgress: (next) => progress.value = next,
      );
      if (!mounted) {
        return;
      }

      if (importedCount <= 0) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('取り込み対象がありませんでした')));
        return;
      }

      _folderItemsCache.clear();
      _folderItemsCacheRecursive.clear();
      _dirStack.clear();

      if (target.activateFolder) {
        await _activateImportedFolder(target.folder);
      }

      await _loadFolder(target.folder, saveAsLast: false);
      if (!mounted) {
        return;
      }

      await _refreshDetailedBrowseIfNeeded();
      await _refreshCurrentPageTags();
      await _refreshArtistTagCounts();

      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('共有ファイルを取り込みました: $importedCount 件')),
      );
    } catch (error, stackTrace) {
      _logUiError('shared-media-import', error, stackTrace);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('共有ファイルの取り込みに失敗しました: $error')));
    } finally {
      progress.dispose();
      await _cleanupPreparedImportSelection(selection);
      if (dialogShown) {
        dialogHandle.close();
      }
    }
  }

  Future<void> _handlePendingSharedUrlImport(List<String> urls) async {
    if (!widget.repo.canImportFromUrl) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('このモードでは共有 URL の取り込みは未対応です')),
      );
      return;
    }

    final target = await _pickSharedImportTarget(
      title: '共有された URL を取り込む',
      subtitle: '${urls.length} 件の URL の保存先を選んでください。',
      currentFolderSubtitle: '表示中のフォルダへ取り込みます',
      librarySubtitle: 'ライブラリへ取り込みます',
    );
    if (target == null) {
      return;
    }

    await _runUrlImport(
      folder: target.folder,
      dialogTitle: '共有された URL を取り込む',
      dialogDescription:
          '共有された URL を確認して取り込みます。必要に応じて Cookie / favorites を調整してください。',
      progressTitle: '共有 URL を取り込み中...',
      successLabel: '共有 URL を取り込みました',
      activateFolder: target.activateFolder,
      initialSourceText: urls.join('\n'),
    );
  }

  Future<_SharedUrlImportTarget?> _pickSharedImportTarget({
    required String title,
    required String subtitle,
    required String currentFolderSubtitle,
    required String librarySubtitle,
  }) async {
    final libraryFolder = await widget.repo.getAppLibraryFolder();
    if (!mounted) {
      return null;
    }

    final currentFolder = _activeImportFolder();
    final currentFolderRaw = currentFolder?.raw.trim();
    final targets = <_SharedUrlImportTarget>[
      if (currentFolderRaw != null && currentFolderRaw.isNotEmpty)
        _SharedUrlImportTarget(
          kind: _SharedUrlImportTargetKind.currentFolder,
          folder: currentFolder!,
          activateFolder: true,
          folderLabel: _folderLabel(currentFolderRaw),
        ),
      if (currentFolderRaw == null || currentFolderRaw != libraryFolder.raw)
        _SharedUrlImportTarget(
          kind: _SharedUrlImportTargetKind.library,
          folder: libraryFolder,
          activateFolder: true,
          folderLabel: _folderLabel(libraryFolder.raw),
        ),
    ];

    if (targets.isEmpty) {
      return null;
    }
    if (targets.length == 1) {
      return targets.first;
    }

    return showControllerModalBottomSheet<_SharedUrlImportTarget>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(title: Text(title), subtitle: Text(subtitle)),
              for (final target in targets)
                ListTile(
                  leading: Icon(
                    target.kind == _SharedUrlImportTargetKind.currentFolder
                        ? Icons.folder_open_outlined
                        : Icons.library_books_outlined,
                  ),
                  title: Text(target.folderLabel),
                  subtitle: Text(
                    target.kind == _SharedUrlImportTargetKind.currentFolder
                        ? currentFolderSubtitle
                        : librarySubtitle,
                  ),
                  onTap: () => Navigator.of(context).pop(target),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _importUrlToLibrary() async {
    if (!widget.repo.canImportFromUrl) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('このモードでは URL 取り込みは未対応です')));
      return;
    }

    final lib = await widget.repo.getAppLibraryFolder();
    final libRaw = lib.raw;
    if (!_foldersRaw.contains(libRaw)) {
      setState(() {
        _foldersRaw = <String>[libRaw, ..._foldersRaw];
      });
      await _persistFolders();
    }

    await _runUrlImport(
      folder: lib,
      dialogTitle: widget.repo.isRemoteMode
          ? 'URLからホストへ取り込み'
          : 'URLからライブラリへ取り込み',
      dialogDescription: widget.repo.isRemoteMode
          ? 'Kemono / Coomer / Hitomi の URL 複数入力や favorites 取得に対応し、hitomi / kemono や作者階層はタグ化してライブラリ直下へ保存します。'
          : Platform.isAndroid
          ? '直接メディア URL を複数入力してライブラリへ保存します。Android のスタンドアロン動作では favorites 取得や Cookie 前提のサイト取り込みは未対応です。'
          : 'Kemono / Coomer / Hitomi の URL 複数入力や favorites 取得に対応し、creator / post フォルダ構成のままライブラリへ保存します。',
      progressTitle: 'URL をダウンロードして取り込み中...',
      successLabel: 'ライブラリへ URL 取り込み',
      activateFolder: true,
    );
  }

  Future<void> _runUrlImport({
    required FolderHandle folder,
    required String dialogTitle,
    required String dialogDescription,
    required String progressTitle,
    required String successLabel,
    bool activateFolder = false,
    String initialSourceText = '',
  }) async {
    final importRequest = await UrlImportDialog.show(
      context,
      title: dialogTitle,
      description: dialogDescription,
      initialSourceText: initialSourceText,
    );
    if (importRequest == null || !importRequest.hasAnySource) {
      return;
    }

    Set<String>? beforeItemIds;
    try {
      final beforeItems = await widget.repo.listMediaRecursiveFiles(folder);
      beforeItemIds = beforeItems
          .where((item) => item.kind != MediaKind.folder)
          .map((item) => item.id)
          .toSet();
    } catch (error) {
      debugPrint('[url-import] failed to snapshot current items: $error');
    }

    final queueId = _nextUrlImportQueueId();
    _addUrlImportQueueEntry(
      _UrlImportQueueEntry(
        id: queueId,
        title: dialogTitle,
        folderLabel: _folderLabel(folder.raw),
        status: _UrlImportQueueStatus.queued,
        startedAt: DateTime.now(),
        message: progressTitle,
      ),
    );

    try {
      _updateUrlImportQueueEntry(
        queueId,
        (current) => current.copyWith(
          status: _UrlImportQueueStatus.running,
          clearMessage: true,
        ),
      );

      final result = await widget.repo.importFromUrlIntoFolder(
        folder,
        importRequest.sourceUrl,
        options: importRequest.options,
        onProgress: (next) {
          _updateUrlImportQueueEntry(
            queueId,
            (current) => current.copyWith(
              status: _UrlImportQueueStatus.running,
              progress: next,
              message: next.statusLabel,
            ),
          );
        },
      );
      if (!mounted) return;

      final observedImport = await _observeUrlImportChanges(
        folder: folder,
        beforeItemIds: beforeItemIds,
      );
      if (!mounted) return;

      final afterItemsSnapshot = observedImport.afterItemsSnapshot;
      var effectiveImportedCount = result.importedCount;
      if (observedImport.observedImportedCount > effectiveImportedCount) {
        debugPrint(
          '[url-import] corrected imported count from '
          '${result.importedCount} to ${observedImport.observedImportedCount} '
          'folder=${folder.raw}',
        );
        effectiveImportedCount = observedImport.observedImportedCount;
      }

      if (effectiveImportedCount <= 0) {
        final message = result.failedCount > 0
            ? 'URL取り込みに失敗しました（失敗: ${result.failedCount} 件）'
            : result.skippedCount > 0
            ? '新規取り込みはありませんでした（スキップ: ${result.skippedCount} 件）'
            : '取り込み対象がありませんでした';
        _updateUrlImportQueueEntry(
          queueId,
          (current) => current.copyWith(
            status: result.failedCount > 0
                ? _UrlImportQueueStatus.failed
                : _UrlImportQueueStatus.empty,
            clearProgress: true,
            message: message,
            finishedAt: DateTime.now(),
          ),
        );
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
        return;
      }

      var inferredTaggedCount = 0;
      if (!widget.repo.isRemoteMode && beforeItemIds != null) {
        inferredTaggedCount = await _applyInferredTagsToImportedItems(
          folder: folder,
          beforeItemIds: beforeItemIds,
          sourceUrl: importRequest.sourceUrl,
          options: importRequest.options,
          afterItemsSnapshot: afterItemsSnapshot,
          hitomiMetadataByRelativePath: result.hitomiMetadataByRelativePath,
        );
      }
      if (widget.repo.isRemoteMode && result.taggedCount > 0) {
        inferredTaggedCount = result.taggedCount;
      }
      if (widget.repo.isRemoteMode && result.taggedCount > 0) {
        inferredTaggedCount = result.taggedCount;
      }

      _folderItemsCache.clear();
      _folderItemsCacheRecursive.clear();
      _dirStack.clear();

      if (activateFolder) {
        await _activateImportedFolder(folder);
      }

      await _loadFolder(folder, saveAsLast: false);
      if (!mounted) return;

      await _refreshDetailedBrowseIfNeeded();
      await _refreshCurrentPageTags();
      await _refreshArtistTagCounts();

      if (!mounted) return;

      final parts = <String>[
        '$effectiveImportedCount 件',
        if (inferredTaggedCount > 0) 'タグ $inferredTaggedCount 件',
        if (result.skippedCount > 0) 'スキップ ${result.skippedCount} 件',
        if (result.failedCount > 0) '失敗 ${result.failedCount} 件',
      ];
      final organizedSummary = result.organizedCount > 0
          ? ' / 整理 ${result.organizedCount} 件'
          : '';
      final message = '$successLabel: ${parts.join(' / ')}$organizedSummary';
      UrlImportDialog.clearBrowserSession();
      _updateUrlImportQueueEntry(
        queueId,
        (current) => current.copyWith(
          status: _UrlImportQueueStatus.completed,
          clearProgress: true,
          message: message,
          finishedAt: DateTime.now(),
        ),
      );
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      final isTimeoutImportError = _isLikelyTimeoutImportError(e);
      if (isTimeoutImportError) {
        _updateUrlImportQueueEntry(
          queueId,
          (current) => current.copyWith(
            status: _UrlImportQueueStatus.running,
            clearProgress: true,
            message: 'サーバー応答がタイムアウトしました。ホスト側の結果を確認中です...',
          ),
        );
      }
      final observedImport = await _observeUrlImportChanges(
        folder: folder,
        beforeItemIds: beforeItemIds,
        attemptCount: isTimeoutImportError ? 30 : 3,
        retryDelay: isTimeoutImportError
            ? const Duration(seconds: 2)
            : const Duration(milliseconds: 600),
      );
      if (observedImport.observedImportedCount > 0) {
        if (!mounted) return;

        var inferredTaggedCount = 0;
        if (!widget.repo.isRemoteMode && beforeItemIds != null) {
          inferredTaggedCount = await _applyInferredTagsToImportedItems(
            folder: folder,
            beforeItemIds: beforeItemIds,
            sourceUrl: importRequest.sourceUrl,
            options: importRequest.options,
            afterItemsSnapshot: observedImport.afterItemsSnapshot,
          );
        }

        _folderItemsCache.clear();
        _folderItemsCacheRecursive.clear();
        _dirStack.clear();

        if (activateFolder) {
          await _activateImportedFolder(folder);
        }

        await _loadFolder(folder, saveAsLast: false);
        if (!mounted) return;

        await _refreshDetailedBrowseIfNeeded();
        await _refreshCurrentPageTags();
        await _refreshArtistTagCounts();

        if (!mounted) return;

        final recoveryNote = isTimeoutImportError
            ? 'ホスト応答はタイムアウトしましたが、取り込み結果を確認できました'
            : 'エラー後に取り込み結果を確認できました';
        final parts = <String>[
          '${observedImport.observedImportedCount} 件',
          if (inferredTaggedCount > 0) 'タグ $inferredTaggedCount 件',
          recoveryNote,
        ];
        final message = '$successLabel: ${parts.join(' / ')}';
        UrlImportDialog.clearBrowserSession();
        _updateUrlImportQueueEntry(
          queueId,
          (current) => current.copyWith(
            status: isTimeoutImportError
                ? _UrlImportQueueStatus.waiting
                : _UrlImportQueueStatus.completed,
            clearProgress: true,
            message: message,
            finishedAt: DateTime.now(),
          ),
        );
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
        return;
      }

      if (!mounted) return;
      if (isTimeoutImportError) {
        final message =
            'サーバー応答がタイムアウトしました。ホスト側で処理が継続している可能性があります。しばらく待ってから再読み込みして結果を確認してください。';
        _updateUrlImportQueueEntry(
          queueId,
          (current) => current.copyWith(
            status: _UrlImportQueueStatus.waiting,
            clearProgress: true,
            message: message,
            finishedAt: DateTime.now(),
          ),
        );
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
        return;
      }
      final message = 'URL取り込みに失敗しました: $e';
      _updateUrlImportQueueEntry(
        queueId,
        (current) => current.copyWith(
          status: _UrlImportQueueStatus.failed,
          clearProgress: true,
          message: message,
          finishedAt: DateTime.now(),
        ),
      );
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<({List<MediaItem>? afterItemsSnapshot, int observedImportedCount})>
  _observeUrlImportChanges({
    required FolderHandle folder,
    required Set<String>? beforeItemIds,
    int attemptCount = 3,
    Duration retryDelay = const Duration(milliseconds: 600),
  }) async {
    if (beforeItemIds == null) {
      return (afterItemsSnapshot: null, observedImportedCount: 0);
    }
    Object? lastError;
    for (var attempt = 0; attempt < attemptCount; attempt++) {
      try {
        final afterItemsSnapshot = await widget.repo.listMediaRecursiveFiles(
          folder,
        );
        final afterItemIds = afterItemsSnapshot
            .where((item) => item.kind != MediaKind.folder)
            .map((item) => item.id)
            .toSet();
        final observedImportedCount = afterItemIds
            .difference(beforeItemIds)
            .length;
        if (observedImportedCount > 0 || attempt == attemptCount - 1) {
          return (
            afterItemsSnapshot: afterItemsSnapshot,
            observedImportedCount: observedImportedCount,
          );
        }
      } catch (error) {
        lastError = error;
        if (attempt == attemptCount - 1) {
          break;
        }
      }
      await Future<void>.delayed(retryDelay);
    }
    if (lastError != null) {
      debugPrint(
        '[url-import] failed to snapshot imported items after import: '
        '$lastError',
      );
    }
    return (afterItemsSnapshot: null, observedImportedCount: 0);
  }

  bool _isLikelyTimeoutImportError(Object error) {
    if (error is TimeoutException) {
      return true;
    }
    final message = error.toString().toLowerCase();
    return message.contains('timeout') || message.contains('タイムアウト');
  }

  Future<int> _applyInferredTagsToImportedItems({
    required FolderHandle folder,
    required Set<String> beforeItemIds,
    required String sourceUrl,
    required UrlImportOptions options,
    List<MediaItem>? afterItemsSnapshot,
    Map<String, HitomiGalleryMetadata> hitomiMetadataByRelativePath =
        const <String, HitomiGalleryMetadata>{},
  }) async {
    try {
      final afterItems =
          afterItemsSnapshot ??
          await widget.repo.listMediaRecursiveFiles(folder);
      final sourceUrls = options.collectSourceUrls(sourceUrl);
      var taggedCount = 0;

      for (final item in afterItems) {
        if (item.kind == MediaKind.folder || beforeItemIds.contains(item.id)) {
          continue;
        }
        if (item.kind != MediaKind.pdf && item.kind != MediaKind.image) {
          continue;
        }

        try {
          final hitomiMetadata = _lookupHitomiMetadataForImportedItem(
            item,
            folderRaw: folder.raw,
            hitomiMetadataByRelativePath: hitomiMetadataByRelativePath,
          );
          final inferred = ImportTagRuleService.inferForImportedItem(
            itemPath: item.id,
            rootFolderRaw: folder.raw,
            displayName: item.displayName,
            sourceUrls: sourceUrls,
            hitomiMetadata: hitomiMetadata,
          );
          final autoImportTags = _filterUrlImportAutoTagsForItem(
            item.kind,
            inferred.tags,
          );
          if (autoImportTags.isEmpty) {
            continue;
          }

          await widget.tagService.addTagsToItem(item, autoImportTags);
          taggedCount++;
          debugPrint(
            '[url-import] inferred tags for ${item.displayName}: '
            '${autoImportTags.map((tag) => '${tag.category.name}:${tag.name}').join(', ')} '
            '(relative=${inferred.relativePathHint})',
          );
        } catch (error) {
          debugPrint(
            '[url-import] failed to assign inferred tags to ${item.displayName}: $error',
          );
        }
      }

      return taggedCount;
    } catch (error) {
      debugPrint('[url-import] inferred tag assignment failed: $error');
      return 0;
    }
  }

  HitomiGalleryMetadata? _lookupHitomiMetadataForImportedItem(
    MediaItem item, {
    required String folderRaw,
    required Map<String, HitomiGalleryMetadata> hitomiMetadataByRelativePath,
  }) {
    if (hitomiMetadataByRelativePath.isEmpty) {
      return null;
    }

    final normalizedFolder = folderRaw.trim();
    final normalizedItemId = item.id.trim();
    if (normalizedFolder.isNotEmpty &&
        normalizedItemId.isNotEmpty &&
        !normalizedFolder.startsWith('content://') &&
        !normalizedItemId.startsWith('content://') &&
        ImportTagRuleService.isWithinLibrary(
          itemPath: normalizedItemId,
          libraryRoot: normalizedFolder,
        )) {
      final relativePath = p.relative(normalizedItemId, from: normalizedFolder);
      final key = HitomiGalleryMetadata.normalizeRelativePathKey(relativePath);
      final exactMatch = key == null ? null : hitomiMetadataByRelativePath[key];
      if (exactMatch != null) {
        return exactMatch;
      }
    }

    final basenameKey = HitomiGalleryMetadata.basenameKey(item.displayName);
    if (basenameKey == null) {
      return null;
    }

    HitomiGalleryMetadata? match;
    for (final entry in hitomiMetadataByRelativePath.entries) {
      if (HitomiGalleryMetadata.basenameKey(entry.key) != basenameKey) {
        continue;
      }
      if (match != null) {
        return null;
      }
      match = entry.value;
    }
    return match;
  }

  Future<void> _refreshAllFavoritesItems() async {
    if (_loadingFavAll) return;
    if (_foldersRaw.isEmpty) {
      if (!mounted) return;
      setState(() => _favoriteItemsAll = const []);
      return;
    }

    setState(() => _loadingFavAll = true);

    try {
      for (final raw in _foldersRaw) {
        if (_folderItemsCache.containsKey(raw)) continue;
        final items = await widget.repo.listMedia(FolderHandle(raw));
        _folderItemsCache[raw] = items;
      }

      final all = <MediaItem>[];
      final resolvedFavoriteIds = <String>{};
      for (final raw in _foldersRaw) {
        final items = _folderItemsCache[raw] ?? const <MediaItem>[];
        for (final item in items) {
          final lookupIds = await widget.tagService.favoriteLookupIdsForItem(
            item,
          );
          if (lookupIds.any(_favorites.contains)) {
            all.add(item);
            resolvedFavoriteIds.addAll(lookupIds);
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _favoriteItemsAll = all.toList(growable: false);
        _favoriteResolvedIds = resolvedFavoriteIds;
      });
    } finally {
      if (mounted) setState(() => _loadingFavAll = false);
    }
  }

  @override
  void dispose() {
    _thumbResumeDebounce?.cancel();
    _homeSearchDebounce?.cancel();
    _externalShareSubscription?.cancel();
    _searchFocusNode
      ..removeListener(_handleGallerySearchFocusChange)
      ..dispose();
    _searchCtrl.dispose();
    _homeSearchCtrl.dispose();
    super.dispose();
  }

  DateTime _safeDateFromDynamic(dynamic v) {
    if (v == null) return DateTime.fromMillisecondsSinceEpoch(0);
    if (v is DateTime) return v;
    if (v is int) {
      if (v < 2000000000) return DateTime.fromMillisecondsSinceEpoch(v * 1000);
      return DateTime.fromMillisecondsSinceEpoch(v);
    }
    if (v is String) {
      final parsed = DateTime.tryParse(v);
      return parsed ?? DateTime.fromMillisecondsSinceEpoch(0);
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  DateTime _getUpdatedAt(MediaItem item) {
    final o = item as dynamic;
    try {
      return _safeDateFromDynamic(o.updatedAt);
    } catch (_) {}
    try {
      return _safeDateFromDynamic(o.modifiedAt);
    } catch (_) {}
    try {
      return _safeDateFromDynamic(o.lastModified);
    } catch (_) {}
    try {
      return _safeDateFromDynamic(o.mtime);
    } catch (_) {}
    try {
      return _safeDateFromDynamic(o.dateModified);
    } catch (_) {}
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  DateTime _getAddedAt(MediaItem item) {
    final o = item as dynamic;
    try {
      return _safeDateFromDynamic(o.addedAt);
    } catch (_) {}
    try {
      return _safeDateFromDynamic(o.createdAt);
    } catch (_) {}
    try {
      return _safeDateFromDynamic(o.ctime);
    } catch (_) {}
    try {
      return _safeDateFromDynamic(o.dateAdded);
    } catch (_) {}
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  List<MediaItem> _applyFilter(
    List<MediaItem> input, {
    required bool? pdfOnly,
  }) {
    Iterable<MediaItem> out = input;

    if (pdfOnly != null) {
      if (pdfOnly) {
        out = out.where(
          (e) => e.kind == MediaKind.folder || e.kind == MediaKind.pdf,
        );
      } else {
        out = out.where(
          (e) => e.kind == MediaKind.folder || e.kind == MediaKind.image,
        );
      }
    }

    final qRaw = _query.trim().toLowerCase();
    if (qRaw.isNotEmpty) {
      final tokens = qRaw
          .split(RegExp(r'\s+'))
          .where((e) => e.isNotEmpty)
          .toList();

      out = out.where((item) {
        final name = item.displayName.toLowerCase();
        final tags = _searchableTagsFor(
          item,
        ).map((e) => e.toLowerCase()).toList(growable: false);
        final detailedTags = _searchableTagDetailsFor(item);

        bool matchToken(String t) {
          if (t == 'untagged' || t == '未分類') {
            return detailedTags.isEmpty;
          }

          final separator = t.indexOf(':');
          if (separator > 0 && separator < t.length - 1) {
            final key = t.substring(0, separator);
            final value = t.substring(separator + 1);
            final category = _tagCategoryForSearchKey(key);

            if (category != null) {
              return detailedTags.any(
                (tag) =>
                    tag.tag.category == category &&
                    tag.tag.name.toLowerCase().contains(value),
              );
            }
          }

          if (t.startsWith('#')) {
            final needle = t.substring(1);
            if (needle.isEmpty) return true;
            return tags.any((x) => x.contains(needle));
          }
          return name.contains(t) || tags.any((x) => x.contains(t));
        }

        for (final t in tokens) {
          if (!matchToken(t)) return false;
        }
        return true;
      });
    }

    final list = out.toList(growable: true);
    switch (_sortMode) {
      case _SortMode.name:
        list.sort(
          (a, b) => a.displayName.toLowerCase().compareTo(
            b.displayName.toLowerCase(),
          ),
        );
        break;
      case _SortMode.updatedAt:
        list.sort((a, b) => _getUpdatedAt(b).compareTo(_getUpdatedAt(a)));
        break;
      case _SortMode.addedAt:
        list.sort((a, b) => _getAddedAt(b).compareTo(_getAddedAt(a)));
        break;
    }

    return list.toList(growable: false);
  }

  List<MediaItem> _applyUntagged(List<MediaItem> input) {
    if (!_currentPageMetadataAvailable) {
      return const <MediaItem>[];
    }
    final base = _applyFilter(input, pdfOnly: null);
    return base
        .where((item) => item.kind != MediaKind.folder)
        .where((item) => _searchableTagDetailsFor(item).isEmpty)
        .toList(growable: false);
  }

  Future<void> _openMetadataSettings() async {
    final previousSettings = widget.tagService.settings;
    final wasHostRunning =
        widget.hostServerService.status.state == HostServerState.running;
    final changed = await MetadataSettingsDialog.show(
      context,
      tagService: widget.tagService,
      hostServerService: widget.hostServerService,
    );
    if (changed != true || !mounted) return;
    await widget.repo.reloadSettings();
    await widget.hostServerService.refresh();
    final nextSettings = widget.tagService.settings;
    final shouldRestartHostServer =
        wasHostRunning &&
        nextSettings.isHostMode &&
        (previousSettings.hostPort != nextSettings.hostPort ||
            (previousSettings.authToken?.trim() ?? '') !=
                (nextSettings.authToken?.trim() ?? '') ||
            previousSettings.hostLibraryPath.trim() !=
                nextSettings.hostLibraryPath.trim());
    if (!nextSettings.isHostMode &&
        widget.hostServerService.status.state == HostServerState.running) {
      await widget.hostServerService.stopServer();
    } else if (shouldRestartHostServer) {
      await widget.hostServerService.stopServer();
      try {
        await widget.hostServerService.startServer(
          tagService: widget.tagService,
        );
      } catch (error, stackTrace) {
        _logUiError('openMetadataSettings.restartServer', error, stackTrace);
      }
    } else if (nextSettings.isHostMode && nextSettings.autoStartHostServer) {
      try {
        await widget.hostServerService.startServer(
          tagService: widget.tagService,
        );
      } catch (error, stackTrace) {
        _logUiError('openMetadataSettings.startServer', error, stackTrace);
      }
    }
    _folderItemsCache.clear();
    _folderItemsCacheRecursive.clear();
    _dirStack.clear();
    await _loadPrefsAndAutoOpenFolder();
    await _refreshCurrentPageTags();
    await _refreshDetailedBrowseIfNeeded();
    await _reloadArtistTagMasters();
    await _checkAppVersionCompatibility();
    if (mounted) {
      setState(() {});
    }
  }

  // ---- AppBar overflow menus ----
  Future<void> _openTagManagementPage() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => TagManagementPage(
          tagService: widget.tagService,
          repo: widget.repo,
          folderRaws: _foldersRaw,
        ),
      ),
    );
    await _reloadArtistTagMasters();
    await _refreshCurrentPageTags();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _onHomeMenuSelected(_HomeMenuAction action) async {
    switch (action) {
      case _HomeMenuAction.addFolder:
        await _addFolder();
        return;
      case _HomeMenuAction.importToLibrary:
        await _importToLibraryAndTag();
        return;
      case _HomeMenuAction.importUrlToLibrary:
        await _importUrlToLibrary();
        return;
      case _HomeMenuAction.artistTagIndex:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ArtistTagIndexPage(
              tagService: widget.tagService,
              repo: widget.repo,
              folderRaws: _foldersRaw,
            ),
          ),
        );
        return;
      case _HomeMenuAction.tagManagement:
        await _openTagManagementPage();
        return;
      case _HomeMenuAction.metadataSettings:
        await _openMetadataSettings();
        return;
      case _HomeMenuAction.refreshFavorites:
        _refreshAllFavoritesItems();
        return;
      case _HomeMenuAction.openSearchGallery:
        _exitSelectMode();
        await _openDetailedBrowsePage();
        return;
    }
  }

  Future<void> _onGalleryMenuSelected(_GalleryMenuAction action) async {
    switch (action) {
      case _GalleryMenuAction.addFolder:
        await _addFolder();
        return;
      case _GalleryMenuAction.addFile:
        if (_currentFolderRaw == null) return;
        _importToCurrentFolder();
        return;
      case _GalleryMenuAction.importUrl:
        if (_currentFolderRaw == null) return;
        await _importUrlToCurrentFolder();
        return;
      case _GalleryMenuAction.exportPdf:
        if (!_repoCapabilities.canExportPdf) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('このモードでは PDF 書き出しは未対応です')),
          );
          return;
        }
        await _exportCurrentFolderImagesToPdf();
        return;
      case _GalleryMenuAction.organizeLibrary:
        if (!_repoCapabilities.canOrganizeLibrary) {
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('このモードではライブラリ整理は未対応です')));
          return;
        }
        _organizeLibrary();
        return;
      case _GalleryMenuAction.tagManagement:
        await _openTagManagementPage();
        return;
      case _GalleryMenuAction.folderTileMode:
        await _showFolderTileModeDialog();
        return;
      case _GalleryMenuAction.metadataSettings:
        await _openMetadataSettings();
        return;
      case _GalleryMenuAction.goHome:
        _exitSelectMode();
        setState(() => _page = _MainPage.home);
        return;
    }
  }

  PopupMenuButton<_HomeMenuAction> _buildHomeOverflowMenu() {
    return PopupMenuButton<_HomeMenuAction>(
      tooltip: 'メニュー',
      icon: const Icon(Icons.more_vert),
      onSelected: _onHomeMenuSelected,
      itemBuilder: (context) => <PopupMenuEntry<_HomeMenuAction>>[
        PopupMenuItem(
          value: _HomeMenuAction.addFolder,
          child: ListTile(
            leading: Icon(_primaryAddActionIcon),
            title: Text(_primaryAddActionLabel),
          ),
        ),
        if (!_repoCapabilities.canImportToHost)
          PopupMenuItem(
            value: _HomeMenuAction.importToLibrary,
            enabled: _repoCapabilities.canUpload,
            child: ListTile(
              leading: const Icon(Icons.archive_outlined),
              title: Text(
                _repoCapabilities.canUpload ? 'ライブラリへ取り込み' : 'ライブラリへ取り込み（未対応）',
              ),
            ),
          ),
        if (widget.repo.canImportFromUrl)
          const PopupMenuItem(
            value: _HomeMenuAction.importUrlToLibrary,
            child: ListTile(
              leading: Icon(Icons.download_for_offline_outlined),
              title: Text('URLからライブラリへ取り込み'),
            ),
          ),
        PopupMenuItem(
          value: _HomeMenuAction.artistTagIndex,
          enabled: _repoCapabilities.canRecursiveSearch,
          child: ListTile(
            leading: Icon(Icons.person),
            title: Text(
              _repoCapabilities.canRecursiveSearch
                  ? 'アーティストタグ一覧'
                  : 'アーティストタグ一覧（未対応）',
            ),
          ),
        ),
        const PopupMenuItem(
          value: _HomeMenuAction.tagManagement,
          child: ListTile(
            leading: Icon(Icons.sell_outlined),
            title: Text('タグ管理'),
          ),
        ),
        const PopupMenuItem(
          value: _HomeMenuAction.metadataSettings,
          child: ListTile(
            leading: Icon(Icons.settings_outlined),
            title: Text('動作モード設定'),
          ),
        ),
        const PopupMenuItem(
          value: _HomeMenuAction.refreshFavorites,
          child: ListTile(leading: Icon(Icons.star), title: Text('お気に入り更新')),
        ),
        PopupMenuItem(
          value: _HomeMenuAction.openSearchGallery,
          enabled: _repoCapabilities.canRecursiveSearch,
          child: ListTile(
            leading: Icon(Icons.view_agenda_outlined),
            title: Text(
              _repoCapabilities.canRecursiveSearch ? '詳細ブラウズ' : '詳細ブラウズ（未対応）',
            ),
          ),
        ),
      ],
    );
  }

  PopupMenuButton<_GalleryMenuAction> _buildGalleryOverflowMenu() {
    return PopupMenuButton<_GalleryMenuAction>(
      tooltip: 'メニュー',
      icon: const Icon(Icons.more_vert),
      onSelected: _onGalleryMenuSelected,
      itemBuilder: (context) => <PopupMenuEntry<_GalleryMenuAction>>[
        const PopupMenuItem(
          value: _GalleryMenuAction.folderTileMode,
          child: ListTile(
            leading: Icon(Icons.folder_open_outlined),
            title: Text('フォルダ表示'),
          ),
        ),
        PopupMenuItem(
          value: _GalleryMenuAction.addFolder,
          child: ListTile(
            leading: Icon(_primaryAddActionIcon),
            title: Text(_primaryAddActionLabel),
          ),
        ),
        if (!_repoCapabilities.canImportToHost)
          PopupMenuItem(
            value: _GalleryMenuAction.addFile,
            enabled: _currentFolderRaw != null && _repoCapabilities.canUpload,
            child: ListTile(
              leading: const Icon(Icons.upload_file_outlined),
              title: Text(
                _repoCapabilities.canUpload
                    ? _galleryAddFileLabel
                    : '$_galleryAddFileLabel（未対応）',
              ),
            ),
          ),
        if (widget.repo.canImportFromUrl)
          PopupMenuItem(
            value: _GalleryMenuAction.importUrl,
            enabled: _currentFolderRaw != null,
            child: const ListTile(
              leading: Icon(Icons.download_for_offline_outlined),
              title: Text('URLから取り込み'),
            ),
          ),
        PopupMenuItem(
          value: _GalleryMenuAction.organizeLibrary,
          enabled: _repoCapabilities.canOrganizeLibrary,
          child: ListTile(
            leading: Icon(Icons.auto_awesome_mosaic_outlined),
            title: Text(
              _repoCapabilities.canOrganizeLibrary
                  ? 'ライブラリ整理（作家・シリーズ）'
                  : 'ライブラリ整理（未対応）',
            ),
          ),
        ),
        const PopupMenuItem(
          value: _GalleryMenuAction.tagManagement,
          child: ListTile(
            leading: Icon(Icons.sell_outlined),
            title: Text('タグ管理'),
          ),
        ),
        const PopupMenuItem(
          value: _GalleryMenuAction.metadataSettings,
          child: ListTile(
            leading: Icon(Icons.settings_outlined),
            title: Text('動作モード設定'),
          ),
        ),
        PopupMenuItem(
          value: _GalleryMenuAction.exportPdf,
          enabled: _repoCapabilities.canExportPdf,
          child: ListTile(
            leading: Icon(Icons.picture_as_pdf_outlined),
            title: Text(
              _repoCapabilities.canExportPdf
                  ? 'このフォルダの画像を PDF にまとめる'
                  : 'このフォルダの画像を PDF にまとめる（未対応）',
            ),
          ),
        ),
        const PopupMenuItem(
          value: _GalleryMenuAction.goHome,
          child: ListTile(
            leading: Icon(Icons.home_outlined),
            title: Text('ホームへ'),
          ),
        ),
      ],
    );
  }

  Future<void> _exportCurrentFolderImagesToPdf() async {
    if (_loading) return;

    final images = _applyFilter(
      _items,
      pdfOnly: false,
    ).where((item) => item.kind == MediaKind.image).toList(growable: false);
    if (images.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('画像がありません')));
      return;
    }

    final folderName = _currentFolderRaw == null
        ? 'export'
        : _folderLabel(_currentFolderRaw!);

    int done = 0;
    final total = images.length;

    showControllerDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('PDF を作成中...'),
        content: StatefulBuilder(
          builder: (context, setD) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: total == 0 ? null : done / total),
              const SizedBox(height: 12),
              Text('$done / $total'),
              const SizedBox(height: 8),
              const Text('保存先フォルダを選択後、処理を開始します。'),
            ],
          ),
        ),
      ),
    );

    try {
      setState(() => _loading = true);

      final created = await PdfExportService.exportFolderToPdfPickLocation(
        widget.repo,
        images,
        folderName,
        onProgress: (d, t) {
          done = d;
          if (mounted) setState(() {});
        },
      );

      if (!mounted) return;
      Navigator.pop(context);

      if (created == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('保存をキャンセルしました')));
      } else {
        final postProcess = await _postProcessGeneratedPdf(
          created: created,
          sourceImages: images,
          sourceFolderLabel: folderName,
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _buildGeneratedPdfResultMessage(
                created: created,
                postProcess: postProcess,
              ),
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('PDF 出力に失敗しました: $e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<_GeneratedPdfPostProcessResult> _postProcessGeneratedPdf({
    required PdfExportResult created,
    required List<MediaItem> sourceImages,
    required String sourceFolderLabel,
  }) async {
    final item = await _buildGeneratedPdfItem(created);
    if (item == null) {
      debugPrint(
        '[pdf-export] skipped post-process: generated item not addressable',
      );
      return const _GeneratedPdfPostProcessResult();
    }

    final sourceFolderRaw =
        _currentFolderRaw ??
        (sourceImages.isNotEmpty
            ? sourceImages.first.folderRaw
            : item.folderRaw);

    FolderHandle? libraryFolder;
    try {
      libraryFolder = await widget.repo.getAppLibraryFolder();
    } catch (error) {
      debugPrint('[pdf-export] getAppLibraryFolder failed: $error');
    }

    final inferred = ImportTagRuleService.inferForGeneratedPdf(
      sourceFolderRaw: sourceFolderRaw,
      sourceFolderLabel: sourceFolderLabel,
      generatedFileName: created.savedName,
      libraryRootRaw: libraryFolder?.raw,
    );
    final inheritedTags = await _collectGeneratedPdfInheritedTags(sourceImages);
    final mergedTags = _filterHitomiPdfAutoTags(<Tag>[
      ...inheritedTags,
      ...inferred.tags,
    ]);
    debugPrint(
      '[pdf-export] inferred tags for ${created.savedName}: '
      '${inferred.tags.map((tag) => '${tag.category.name}:${tag.name}').join(', ')} '
      '(relative=${inferred.relativePathHint})',
    );
    debugPrint(
      '[pdf-export] inherited tags for ${created.savedName}: '
      '${inheritedTags.map((tag) => '${tag.category.name}:${tag.name}').join(', ')}',
    );

    String? tagErrorMessage;
    if (mergedTags.isNotEmpty) {
      try {
        await widget.tagService.addTagsToItem(item, mergedTags);
      } catch (error) {
        tagErrorMessage = '$error';
        debugPrint('[pdf-export] tag assignment failed: $error');
      }
    }

    String? organizeErrorMessage;
    String? organizedPath;
    var refreshedCurrentFolder = false;
    if (tagErrorMessage == null &&
        mergedTags.isNotEmpty &&
        libraryFolder != null &&
        _repoCapabilities.canOrganizeLibrary &&
        ImportTagRuleService.isWithinLibrary(
          itemPath: item.id,
          libraryRoot: libraryFolder.raw,
        )) {
      try {
        final moved = await widget.tagService.organizeAppLibrary(
          libraryRoot: libraryFolder.raw,
        );
        organizedPath = moved[item.id];
        if (organizedPath != null) {
          _folderItemsCache.clear();
          _folderItemsCacheRecursive.clear();
          if (_currentFolderRaw != null &&
              _currentFolderRaw!.startsWith(libraryFolder.raw)) {
            refreshedCurrentFolder = true;
            await _loadFolder(
              FolderHandle(_currentFolderRaw!),
              saveAsLast: false,
              pageIndex: _galleryPageIndex,
            );
          }
        }
      } catch (error) {
        organizeErrorMessage = '$error';
        debugPrint('[pdf-export] organize after export failed: $error');
      }
    }

    if (!refreshedCurrentFolder &&
        _currentFolderRaw != null &&
        (created.savedFolderRaw?.trim().isNotEmpty ?? false) &&
        _sameFolderLocation(_currentFolderRaw!, created.savedFolderRaw!)) {
      _folderItemsCache.remove(_currentFolderRaw!);
      _folderItemsCacheRecursive.remove(_currentFolderRaw!);
      await _loadFolder(
        FolderHandle(_currentFolderRaw!),
        saveAsLast: false,
        pageIndex: _galleryPageIndex,
      );
    }

    return _GeneratedPdfPostProcessResult(
      item: item,
      inferredTags: mergedTags,
      relativePathHint: inferred.relativePathHint,
      tagErrorMessage: tagErrorMessage,
      organizeErrorMessage: organizeErrorMessage,
      organizedPath: organizedPath,
    );
  }

  Future<List<Tag>> _collectGeneratedPdfInheritedTags(
    List<MediaItem> sourceImages,
  ) async {
    final imageSources = sourceImages
        .where((item) => item.kind == MediaKind.image)
        .toList(growable: false);
    if (imageSources.isEmpty) {
      return const <Tag>[];
    }

    final knownDetails = <String, List<TagWithId>>{};
    for (final item in imageSources) {
      final cached = _tagDetailsById[item.id];
      if (cached != null) {
        knownDetails[item.id] = cached;
      }
    }

    Map<String, List<TagWithId>> details = knownDetails;
    if (details.length != imageSources.length) {
      try {
        details = await widget.tagService.getDetailedTagsByItems(imageSources);
      } catch (error) {
        debugPrint('[pdf-export] source tag lookup failed: $error');
      }
    }

    final out = <Tag>[];
    final seen = <String>{};
    for (final item in imageSources) {
      for (final entry in details[item.id] ?? const <TagWithId>[]) {
        final tag = entry.tag;
        final isArtist = tag.category == TagCategory.artist;
        final isImportSourceMediaType =
            tag.category == TagCategory.mediaType &&
            _isImportPdfAutoTagMediaType(tag.name);
        if (!isArtist && !isImportSourceMediaType) {
          continue;
        }
        final key = '${tag.category.name}\u0000${tag.name.toLowerCase()}';
        if (!seen.add(key)) {
          continue;
        }
        out.add(Tag(name: tag.name, category: tag.category));
      }
    }
    return out;
  }

  List<Tag> _filterUrlImportAutoTagsForItem(
    MediaKind kind,
    Iterable<Tag> tags,
  ) {
    if (kind == MediaKind.pdf) {
      return _filterHitomiPdfAutoTags(tags);
    }

    final out = <Tag>[];
    final seen = <String>{};
    for (final tag in tags) {
      final normalizedName = tag.name.trim();
      if (normalizedName.isEmpty) {
        continue;
      }
      final isSupportedMediaType =
          tag.category == TagCategory.mediaType &&
          _isImportPdfAutoTagMediaType(normalizedName);
      if (!isSupportedMediaType) {
        continue;
      }

      final key = '${tag.category.name}\u0000${normalizedName.toLowerCase()}';
      if (!seen.add(key)) {
        continue;
      }
      out.add(Tag(name: normalizedName, category: tag.category));
    }
    return out;
  }

  List<Tag> _filterHitomiPdfAutoTags(Iterable<Tag> tags) {
    final out = <Tag>[];
    final seen = <String>{};
    var hasSupportedMediaType = false;

    for (final tag in tags) {
      final normalizedName = tag.name.trim();
      if (normalizedName.isEmpty) {
        continue;
      }

      final isArtist = tag.category == TagCategory.artist;
      final isSeries = tag.category == TagCategory.series;
      final isCharacter = tag.category == TagCategory.character;
      final isFree = tag.category == TagCategory.free;
      final isSupportedMediaType =
          tag.category == TagCategory.mediaType &&
          _isImportPdfAutoTagMediaType(normalizedName);
      if (!isArtist &&
          !isSeries &&
          !isCharacter &&
          !isFree &&
          !isSupportedMediaType) {
        continue;
      }

      if (isSupportedMediaType) {
        hasSupportedMediaType = true;
      }

      final key = '${tag.category.name}\u0000${normalizedName.toLowerCase()}';
      if (!seen.add(key)) {
        continue;
      }
      out.add(Tag(name: normalizedName, category: tag.category));
    }

    if (!hasSupportedMediaType) {
      return const <Tag>[];
    }
    return out;
  }

  bool _isImportPdfAutoTagMediaType(String name) {
    final normalized = name.trim().toLowerCase();
    return normalized == 'hitomi' || normalized == 'ddd-smart';
  }

  Future<MediaItem?> _buildGeneratedPdfItem(PdfExportResult created) async {
    if ((created.savedPath?.trim().isNotEmpty ?? false)) {
      final path = created.savedPath!.trim();
      try {
        final file = File(path);
        final stat = await file.stat();
        return MediaItem(
          id: file.path,
          displayName: created.savedName,
          kind: MediaKind.pdf,
          folderRaw: created.savedFolderRaw ?? file.parent.path,
          modified: stat.modified,
          sizeBytes: stat.size,
          tags: const <Tag>[],
        );
      } catch (error) {
        debugPrint('[pdf-export] failed to stat generated file: $error');
      }
    }

    if ((created.savedUri?.trim().isNotEmpty ?? false)) {
      return MediaItem(
        id: created.savedUri!.trim(),
        displayName: created.savedName,
        kind: MediaKind.pdf,
        folderRaw: (created.savedFolderRaw ?? created.savedUri!).trim(),
        modified: DateTime.now(),
        tags: const <Tag>[],
      );
    }

    return null;
  }

  String _buildGeneratedPdfResultMessage({
    required PdfExportResult created,
    required _GeneratedPdfPostProcessResult postProcess,
  }) {
    final parts = <String>['PDF を保存しました: ${created.name}'];
    if (postProcess.inferredTags.isNotEmpty) {
      parts.add('タグ ${postProcess.inferredTags.length} 件を付与');
    }
    if (postProcess.organized) {
      parts.add('既存整理で階層反映');
    }
    if (postProcess.hasTagFailure) {
      parts.add('タグ付与失敗: ${postProcess.tagErrorMessage}');
    }
    if (postProcess.hasOrganizeFailure) {
      parts.add('整理失敗: ${postProcess.organizeErrorMessage}');
    }
    return parts.join(' / ');
  }

  Future<void> _showFolderTileModeDialog() async {
    final mode = await showControllerDialog<FolderTileMode>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('フォルダ表示設定'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, FolderTileMode.labelOnly),
            child: const Text('フォルダ名のみ（軽量）'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, FolderTileMode.preview),
            child: const Text('プレビュー表示（重め）'),
          ),
        ],
      ),
    );

    if (mode == null) return;
    _saveFolderTileMode(mode);
  }

  // --- UI: responsive sidebar (Windows/desktop friendly) ---
  static const double _kSidebarWidth = 340;

  bool _isWideLayout(BuildContext context) =>
      MediaQuery.of(context).size.width >= 980;

  void _closeSidebar() {
    if (!_isWideLayout(context)) {
      Navigator.pop(context);
    }
  }

  Widget _withSidebar(BuildContext context, Widget body) {
    if (!_isWideLayout(context)) return body;
    return Row(
      children: [
        SizedBox(width: _kSidebarWidth, child: _buildSidebarPanel()),
        const VerticalDivider(width: 1),
        Expanded(child: body),
      ],
    );
  }

  Widget _sidebarHeader() {
    final currentLabel = _currentFolderRaw == null
        ? '未選択'
        : _folderLabel(_currentFolderRaw!);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('メディアビューア', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            '現在のフォルダ: $currentLabel',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _sidebarSectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  Drawer _buildSidebar() =>
      Drawer(child: SafeArea(child: _buildSidebarListView()));

  Widget _buildSidebarPanel() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: SafeArea(child: _buildSidebarListView()),
    );
  }

  Widget _buildSidebarListView() {
    return RefreshIndicator(
      onRefresh: _handlePullToRefresh,
      child: ListView(
        physics: _refreshScrollPhysics,
        padding: EdgeInsets.zero,
        children: [
          _sidebarHeader(),
          ListTile(
            leading: const Icon(Icons.home_outlined),
            title: const Text('ホーム'),
            selected: _page == _MainPage.home,
            onTap: () {
              _closeSidebar();
              _exitSelectMode();
              setState(() => _page = _MainPage.home);
            },
          ),
          ListTile(
            leading: const Icon(Icons.grid_view),
            title: const Text('ギャラリー'),
            selected: _page == _MainPage.gallery,
            onTap: () async {
              _closeSidebar();
              if (_currentFolderRaw == null) {
                _exitSelectMode();
                setState(() => _page = _MainPage.home);
                return;
              }
              _exitSelectMode();
              setState(() => _page = _MainPage.gallery);
            },
          ),
          ListTile(
            leading: const Icon(Icons.view_agenda_outlined),
            title: const Text('詳細ブラウズ'),
            selected: _page == _MainPage.search,
            onTap: () async {
              _closeSidebar();
              _exitSelectMode();
              await _openDetailedBrowsePage();
            },
          ),
          const Divider(),
          _sidebarSectionLabel('作家タグ'),
          if (_loadingArtistTags)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: LinearProgressIndicator(),
            )
          else
            ExpansionTile(
              leading: const Icon(Icons.person_outline),
              title: const Text('作家（カテゴリ）'),
              children: [
                if (_artistTagMasters.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    child: Text('作家タグがまだありません'),
                  )
                else
                  ..._artistTagMasters.map((tagWithId) {
                    final name = tagWithId.tag.name;
                    final count = _tagCountCache[name.toLowerCase()] ?? 0;
                    return ListTile(
                      leading: const Icon(Icons.label_outline),
                      title: Text(name),
                      trailing: Text('$count'),
                      onTap: () => _openTagGalleryFromDrawer(name),
                    );
                  }),
              ],
            ),
          _sidebarSectionLabel('表示設定'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: InputDecorator(
              decoration: const InputDecoration(
                labelText: '表示フィット',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<ReaderFitMode>(
                  value: _fitMode,
                  isDense: true,
                  items: const [
                    DropdownMenuItem(
                      value: ReaderFitMode.vertical,
                      child: Text('縦フィット'),
                    ),
                    DropdownMenuItem(
                      value: ReaderFitMode.horizontal,
                      child: Text('横フィット'),
                    ),
                    DropdownMenuItem(
                      value: ReaderFitMode.contain,
                      child: Text('全体表示 (Contain)'),
                    ),
                  ],
                  onChanged: (value) async {
                    if (value == null) return;
                    setState(() => _fitMode = value);
                    await _saveFitMode(value);
                  },
                ),
              ),
            ),
          ),
          SwitchListTile(
            title: const Text('見開き表示 (ON/OFF)'),
            value: _twoPage,
            onChanged: (value) async {
              setState(() => _twoPage = value);
              await _saveTwoPage(value);
            },
          ),
          ListTile(
            leading: const Icon(Icons.settings_ethernet),
            title: const Text('メタデータ設定'),
            subtitle: Text(
              widget.tagService.isRemoteMode
                  ? '現在: リモート API モード'
                  : '現在: ローカル DB モード',
            ),
            onTap: () async {
              _closeSidebar();
              await _openMetadataSettings();
            },
          ),
          const Divider(),
          _sidebarSectionLabel('フォルダ'),
          ListTile(
            leading: Icon(_primaryAddActionIcon),
            title: Text(_primaryAddActionLabel),
            onTap: () async {
              _closeSidebar();
              await _addFolder();
            },
          ),
          if (widget.repo.canImportFromUrl)
            ListTile(
              leading: const Icon(Icons.download_for_offline_outlined),
              title: const Text('URLからライブラリへ取り込み'),
              onTap: () async {
                _closeSidebar();
                await _importUrlToLibrary();
              },
            ),
          if (_foldersRaw.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                '登録フォルダがありません。上の「$_primaryAddActionLabel」から追加してください。',
              ),
            )
          else ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 6, 16, 6),
              child: Text('タップで切替 / ゴミ箱で削除'),
            ),
            for (final raw in _foldersRaw)
              ListTile(
                leading: Icon(
                  raw == _currentFolderRaw
                      ? Icons.folder
                      : Icons.folder_outlined,
                ),
                title: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _folderLabel(raw),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (raw == _currentFolderRaw)
                      const Padding(
                        padding: EdgeInsets.only(left: 8),
                        child: Chip(
                          label: Text('選択中'),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                  ],
                ),
                subtitle: Text(
                  raw,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                selected: raw == _currentFolderRaw,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '名前を変更',
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () async {
                        _closeSidebar();
                        await _renameFolder(raw);
                      },
                    ),
                    IconButton(
                      tooltip: 'このフォルダを削除',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        _closeSidebar();
                        await _removeFolder(raw);
                      },
                    ),
                  ],
                ),
                onTap: () async {
                  _closeSidebar();
                  await _switchFolder(raw);
                },
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text(
                '登録フォルダと選択中フォルダは別管理です。必要に応じて切り替えてください。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _nextUrlImportQueueId() =>
      'url-import-${DateTime.now().microsecondsSinceEpoch}';

  void _addUrlImportQueueEntry(_UrlImportQueueEntry entry) {
    setState(() {
      _urlImportQueue.insert(0, entry);
      while (_urlImportQueue.length > 8) {
        _urlImportQueue.removeLast();
      }
      _showUrlImportQueue = true;
    });
  }

  void _updateUrlImportQueueEntry(
    String id,
    _UrlImportQueueEntry Function(_UrlImportQueueEntry current) update,
  ) {
    if (!mounted) return;
    setState(() {
      final index = _urlImportQueue.indexWhere((entry) => entry.id == id);
      if (index < 0) return;
      _urlImportQueue[index] = update(_urlImportQueue[index]);
    });
  }

  void _removeUrlImportQueueEntry(String id) {
    if (!mounted) return;
    setState(() {
      _urlImportQueue.removeWhere((entry) => entry.id == id);
    });
  }

  String _queueStatusLabel(_UrlImportQueueEntry entry) {
    switch (entry.status) {
      case _UrlImportQueueStatus.queued:
        return '待機中';
      case _UrlImportQueueStatus.running:
        return entry.progress?.statusLabel ?? 'ダウンロード中';
      case _UrlImportQueueStatus.waiting:
        return '確認待ち';
      case _UrlImportQueueStatus.completed:
        return '完了';
      case _UrlImportQueueStatus.empty:
        return '差分なし';
      case _UrlImportQueueStatus.failed:
        return '失敗';
    }
  }

  Color _queueStatusColor(BuildContext context, _UrlImportQueueEntry entry) {
    switch (entry.status) {
      case _UrlImportQueueStatus.waiting:
        return Colors.orange.shade400;
      case _UrlImportQueueStatus.completed:
        return Colors.green.shade400;
      case _UrlImportQueueStatus.empty:
        return Theme.of(context).colorScheme.primary;
      case _UrlImportQueueStatus.failed:
        return Theme.of(context).colorScheme.error;
      case _UrlImportQueueStatus.queued:
      case _UrlImportQueueStatus.running:
        return Theme.of(context).colorScheme.outline;
    }
  }

  Widget _buildUrlImportQueueOverlay() {
    if (_urlImportQueue.isEmpty) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    return Positioned(
      right: 16,
      bottom: 16,
      child: SafeArea(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360, maxHeight: 420),
          child: Card(
            elevation: 6,
            child: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.download_outlined),
                    title: Text('ダウンロードキュー (${_urlImportQueue.length})'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: _showUrlImportQueue ? '折りたたむ' : '展開',
                          onPressed: () {
                            setState(
                              () => _showUrlImportQueue = !_showUrlImportQueue,
                            );
                          },
                          icon: Icon(
                            _showUrlImportQueue
                                ? Icons.expand_more
                                : Icons.chevron_left,
                          ),
                        ),
                        IconButton(
                          tooltip: '完了済みを閉じる',
                          onPressed: () {
                            setState(() {
                              _urlImportQueue.removeWhere(
                                (entry) =>
                                    entry.status !=
                                        _UrlImportQueueStatus.running &&
                                    entry.status !=
                                        _UrlImportQueueStatus.queued,
                              );
                            });
                          },
                          icon: const Icon(Icons.clear_all),
                        ),
                      ],
                    ),
                  ),
                  if (_showUrlImportQueue)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 320),
                      child: ListView.separated(
                        shrinkWrap: true,
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                        itemCount: _urlImportQueue.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final entry = _urlImportQueue[index];
                          final progress = entry.progress;
                          final total = progress?.totalFiles ?? 0;
                          final completed = progress?.completedFiles ?? 0;
                          final showLinear =
                              entry.status == _UrlImportQueueStatus.running;
                          final linearValue = total > 0
                              ? progress?.fraction
                              : null;

                          return Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: _queueStatusColor(context, entry),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            entry.title,
                                            style: theme.textTheme.titleSmall,
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            entry.folderLabel,
                                            style: theme.textTheme.bodySmall,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    IconButton(
                                      tooltip: '閉じる',
                                      onPressed: () =>
                                          _removeUrlImportQueueEntry(entry.id),
                                      icon: const Icon(Icons.close, size: 18),
                                    ),
                                  ],
                                ),
                                Text(
                                  _queueStatusLabel(entry),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: _queueStatusColor(context, entry),
                                  ),
                                ),
                                if (showLinear) ...[
                                  const SizedBox(height: 8),
                                  LinearProgressIndicator(value: linearValue),
                                  const SizedBox(height: 6),
                                  Text(
                                    total == 0
                                        ? '準備中...'
                                        : '$completed / $total',
                                  ),
                                ],
                                if (progress?.currentFileName != null) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    progress!.currentFileName!,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ],
                                if (entry.message != null) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    entry.message!,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ],
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _wrapBodyWithUrlImportQueue(Widget body) {
    return Stack(
      fit: StackFit.expand,
      children: [body, _buildUrlImportQueueOverlay()],
    );
  }

  List<MediaItem> _gallerySelectionView(int tabIndex) {
    switch (tabIndex) {
      case 1:
        return _applyUntagged(_gallerySearchBaseItems());
      case 2:
        return _applyFilter(_favoriteItemsAll, pdfOnly: null);
      default:
        return _applyFilter(_gallerySearchBaseItems(), pdfOnly: null);
    }
  }

  List<Widget> _buildSearchAppBarActions() {
    if (_selectMode) {
      return _appendTopBarRescanAction([
        IconButton(
          tooltip: '選択解除',
          onPressed: _exitSelectMode,
          icon: const Icon(Icons.close),
        ),
        IconButton(
          tooltip: '全選択',
          onPressed: () => _selectAll(_homeSearchResults),
          icon: const Icon(Icons.select_all),
        ),
        IconButton(
          tooltip: 'クリア',
          onPressed: _clearSelection,
          icon: const Icon(Icons.clear_all),
        ),
        IconButton(
          tooltip: '選択中に一括タグ付け',
          onPressed: () {
            final targets = _selectedFrom(_homeSearchResults);
            _bulkAddTagToItems(targets);
          },
          icon: const Icon(Icons.label_outline),
        ),
        IconButton(
          tooltip: '選択中を削除',
          onPressed: () {
            final targets = _selectedFrom(_homeSearchResults);
            _deleteItemsFromList(targets);
          },
          icon: const Icon(Icons.delete_outline),
        ),
        IconButton(
          tooltip: '選択中をライブラリに取り込む（重複はスキップ）',
          onPressed: () {
            final targets = _selectedFrom(_homeSearchResults);
            _importSelectedToLibrary(targets);
          },
          icon: const Icon(Icons.archive_outlined),
        ),
      ]);
    }

    return _appendTopBarRescanAction([
      IconButton(
        tooltip: 'ホームへ',
        onPressed: () {
          _exitSelectMode();
          setState(() => _page = _MainPage.home);
        },
        icon: const Icon(Icons.home_outlined),
      ),
      IconButton(
        tooltip: 'ギャラリーへ',
        onPressed: () {
          _exitSelectMode();
          setState(() => _page = _MainPage.gallery);
        },
        icon: const Icon(Icons.photo_library_outlined),
      ),
    ]);
  }

  List<Widget> _buildGalleryAppBarActions(TabController controller) {
    if (!_selectMode) {
      return _appendTopBarRescanAction(<Widget>[_buildGalleryOverflowMenu()]);
    }

    return _appendTopBarRescanAction([
      IconButton(
        tooltip: '選択解除',
        onPressed: _exitSelectMode,
        icon: const Icon(Icons.close),
      ),
      IconButton(
        tooltip: '全選択（現在タブ）',
        onPressed: () {
          final view = _gallerySelectionView(controller.index);
          _selectAll(view);
        },
        icon: const Icon(Icons.select_all),
      ),
      IconButton(
        tooltip: 'クリア',
        onPressed: _clearSelection,
        icon: const Icon(Icons.clear_all),
      ),
      IconButton(
        tooltip: '選択中に一括タグ付け',
        onPressed: () {
          final view = _gallerySelectionView(controller.index);
          final targets = _selectedFrom(view);
          _bulkAddTagToItems(targets);
        },
        icon: const Icon(Icons.label_outline),
      ),
      IconButton(
        tooltip: '選択中を削除',
        onPressed: () {
          final view = _gallerySelectionView(controller.index);
          final targets = _selectedFrom(view);
          _deleteItemsFromList(targets);
        },
        icon: const Icon(Icons.delete_outline),
      ),
      IconButton(
        tooltip: '選択中をライブラリに取り込む（重複はスキップ）',
        onPressed: () {
          final view = _gallerySelectionView(controller.index);
          final targets = _selectedFrom(view);
          _importSelectedToLibrary(targets);
        },
        icon: const Icon(Icons.archive_outlined),
      ),
    ]);
  }

  Widget _buildGalleryMainBody() {
    if (_initializing) {
      return _buildRefreshableStatusBody(
        onRefresh: _handlePullToRefresh,
        child: _buildLoadingBody(
          title: '初期化中です',
          message: '設定とフォルダ情報を読み込んでいます。',
        ),
      );
    }

    if (_initializationErrorMessage != null) {
      return _buildRefreshableStatusBody(
        onRefresh: _handlePullToRefresh,
        child: _buildErrorBody(
          title: '初期化に失敗しました',
          message: _initializationErrorMessage!,
          onAction: _retryInitialization,
        ),
      );
    }

    if (_folder == null) {
      if (_foldersRaw.isEmpty) {
        return _buildRefreshableStatusBody(
          onRefresh: _handlePullToRefresh,
          child: _buildEmptyBody(
            title: '表示できるフォルダがありません',
            message: 'まずは $_primaryAddActionLabel を実行してください。',
            actionLabel: _primaryAddActionLabel,
            onAction: _addFolder,
          ),
        );
      }
      return _buildRefreshableStatusBody(
        onRefresh: _handlePullToRefresh,
        child: _buildEmptyBody(
          title: 'フォルダが未選択です',
          message: 'サイドバーまたはホーム画面から表示するフォルダを選択してください。',
          actionLabel: 'ホームを開く',
          onAction: () => setState(() => _page = _MainPage.home),
        ),
      );
    }

    if (_galleryLoadErrorMessage != null && !_loading) {
      return _buildRefreshableStatusBody(
        onRefresh: _handlePullToRefresh,
        child: _buildErrorBody(
          title: 'フォルダを読み込めませんでした',
          message: _galleryLoadErrorMessage!,
          onAction: () => _loadFolder(
            _folder!,
            saveAsLast: false,
            pageIndex: _galleryPageIndex,
          ),
        ),
      );
    }

    if (_loading) {
      final progress = _loadTotal > 0 ? _loadProcessed / _loadTotal : null;
      final message = _loadTotal > 0
          ? '$_loadProcessed / $_loadTotal 件を読み込んでいます。'
          : 'フォルダの内容を読み込んでいます。';
      return _buildRefreshableStatusBody(
        onRefresh: _handlePullToRefresh,
        child: _buildLoadingBody(
          title: 'フォルダを読み込んでいます',
          message: message,
          progress: progress,
        ),
      );
    }

    if (_items.isEmpty) {
      return _buildRefreshableStatusBody(
        onRefresh: _handlePullToRefresh,
        child: _buildEmptyBody(
          title: 'このフォルダに画像や PDF がありません',
          message: '別のフォルダを選ぶか、$_galleryAddFileLabel を実行してください。',
          actionLabel: _galleryAddFileLabel,
          onAction: _repoCapabilities.canUpload ? _importToCurrentFolder : null,
        ),
      );
    }

    final galleryItems = _gallerySelectionView(0);
    final untaggedItems = _gallerySelectionView(1);
    final favoriteItems = _gallerySelectionView(2);
    final showPager = !_isGallerySearchActive;

    return TabBarView(
      children: [
        _buildGrid(
          galleryItems,
          showPager: showPager,
          onRefresh: _handlePullToRefresh,
        ),
        _currentPageMetadataAvailable
            ? _buildGrid(
                untaggedItems,
                showPager: showPager,
                onRefresh: _handlePullToRefresh,
              )
            : _buildRefreshableStatusBody(
                onRefresh: _handlePullToRefresh,
                child: _buildEmptyBody(
                  title: 'タグ情報を読み込めませんでした',
                  message: 'タグなし一覧はメタデータが取得できたときだけ表示されます。',
                ),
              ),
        _loadingFavAll
            ? _buildRefreshableStatusBody(
                onRefresh: _handlePullToRefresh,
                child: _buildLoadingBody(
                  title: 'お気に入りを集計しています',
                  message: '登録済みのお気に入りを確認しています。',
                ),
              )
            : _buildGrid(
                favoriteItems,
                showFolderLabel: true,
                showPager: false,
                onRefresh: _handlePullToRefresh,
              ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_page == _MainPage.home) {
      return ControllerNavigationRegion(
        key: const ValueKey<String>('gallery-home'),
        debugLabel: 'gallery-home',
        autofocusFirstFocusable: true,
        child: Scaffold(
          drawer: _isWideLayout(context) ? null : _buildSidebar(),
          appBar: AppBar(
            title: const Text('ホーム'),
            actions: _appendTopBarRescanAction([_buildHomeOverflowMenu()]),
          ),
          body: _wrapBodyWithUrlImportQueue(
            _withSidebar(
              context,
              _buildGuardedBody('home-body', _buildHomeBody),
            ),
          ),
        ),
      );
    }

    if (_page == _MainPage.search) {
      return ControllerNavigationRegion(
        key: const ValueKey<String>('gallery-search'),
        debugLabel: 'gallery-search',
        autofocusFirstFocusable: true,
        child: Scaffold(
          drawer: _isWideLayout(context) ? null : _buildSidebar(),
          appBar: AppBar(
            title: const Text('詳細ブラウズ'),
            actions: _buildSearchAppBarActions(),
          ),
          body: _wrapBodyWithUrlImportQueue(
            _withSidebar(
              context,
              _buildGuardedBody('search-body', _buildHomeSearchGalleryBody),
            ),
          ),
        ),
      );
    }

    return ControllerNavigationRegion(
      key: const ValueKey<String>('gallery-main'),
      debugLabel: 'gallery-main',
      autofocusFirstFocusable: true,
      child: DefaultTabController(
        length: 3,
        child: Builder(
          builder: (context) {
            final tabController = DefaultTabController.of(context);
            if (!_tabListenerInstalled) {
              _tabListenerInstalled = true;
              tabController.addListener(() {
                if (!tabController.indexIsChanging &&
                    tabController.index == 2) {
                  _refreshAllFavoritesItems();
                }
              });
            }

            final seriesFilterChips = _currentFolderSeriesFilterChips();
            final showSeriesFilterRow =
                _gallerySearchLoading ||
                _gallerySearchLoadingTags ||
                seriesFilterChips.isNotEmpty;

            return Scaffold(
              drawer: _isWideLayout(context) ? null : _buildSidebar(),
              appBar: AppBar(
                leading: _canGoUp
                    ? IconButton(
                        tooltip: '親フォルダへ',
                        icon: const Icon(Icons.arrow_back),
                        onPressed: () {
                          _exitSelectMode();
                          _goUpFolder();
                        },
                      )
                    : null,
                title: Text(
                  _folder == null
                      ? '一覧表示'
                      : '一覧表示: ${_folderLabel(_folder!.raw)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                actions: _buildGalleryAppBarActions(tabController),
                bottom: PreferredSize(
                  preferredSize: Size.fromHeight(
                    showSeriesFilterRow ? 206 : 160,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                        child: SizedBox(
                          height: 44,
                          child: _buildGallerySearchField(),
                        ),
                      ),
                      if (showSeriesFilterRow)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                          child: _buildGallerySeriesFilterRow(
                            seriesFilterChips,
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: SizedBox(
                          height: 36,
                          child: Row(
                            children: [
                              const Text('ソート'),
                              const SizedBox(width: 8),
                              DropdownButton<_SortMode>(
                                value: _sortMode,
                                items: const [
                                  DropdownMenuItem(
                                    value: _SortMode.name,
                                    child: Text('名前'),
                                  ),
                                  DropdownMenuItem(
                                    value: _SortMode.updatedAt,
                                    child: Text('更新日'),
                                  ),
                                  DropdownMenuItem(
                                    value: _SortMode.addedAt,
                                    child: Text('追加日'),
                                  ),
                                ],
                                onChanged: (value) {
                                  if (value == null) return;
                                  setState(() => _sortMode = value);
                                },
                              ),
                              const Spacer(),
                              if (_loading) ...[
                                if (_loadTotal > 0)
                                  Text(
                                    '${((_loadProcessed / _loadTotal) * 100).clamp(0, 100).toStringAsFixed(0)}%',
                                  )
                                else
                                  const Text('...'),
                                const SizedBox(width: 8),
                                const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const TabBar(
                        isScrollable: true,
                        tabs: [
                          Tab(text: 'すべて'),
                          Tab(text: 'タグなし'),
                          Tab(text: 'お気に入り'),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              body: _wrapBodyWithUrlImportQueue(
                _withSidebar(
                  context,
                  _buildGuardedBody('gallery-body', _buildGalleryMainBody),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _bulkAddTagToItems(List<MediaItem> targets) async {
    final mediaTargets = targets
        .where((item) => item.kind != MediaKind.folder)
        .toList(growable: false);
    if (mediaTargets.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('対象がありません')));
      return;
    }

    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => TagAssignAfterImportPage(
          items: mediaTargets,
          tagService: widget.tagService,
          title: '一括タグ付与（${mediaTargets.length}件）',
          applyLabel: '${mediaTargets.length}件にタグを付ける',
        ),
      ),
    );

    if (changed != true || !mounted) {
      return;
    }

    try {
      final got = await widget.tagService.getTagNamesByItems(mediaTargets);
      if (!mounted) return;
      setState(() {
        for (final e in got.entries) {
          for (final vv in _idVariants(e.key)) {
            _dbTagsByItemId[vv] = e.value;
          }
        }
      });
      await _refreshCurrentPageTags();
      await _refreshArtistTagCounts();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${mediaTargets.length}件にタグを付与しました')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('タグ反映の更新に失敗しました: $e')));
    }
  }

  Future<void> _importSelectedToLibrary(List<MediaItem> targets) async {
    final mediaTargets = targets
        .where((item) => item.kind != MediaKind.folder)
        .toList(growable: false);
    if (mediaTargets.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('取り込み対象がありません')));
      return;
    }
    if (!_repoCapabilities.canUpload) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('このモードでは取り込みは未対応です')));
      return;
    }

    final lib = await widget.repo.getAppLibraryFolder();

    final before = await widget.repo.listMedia(lib);
    final beforeIds = before.map((e) => e.id).toSet();

    final imported = await widget.repo.importItemsIntoFolder(
      lib,
      mediaTargets,
      skipIfExists: true,
    );

    if (imported <= 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('取り込み対象がありません（既に取り込み済みの可能性）')),
      );
      return;
    }

    final after = await widget.repo.listMedia(lib);
    final newItems = after
        .where((e) => e.kind != MediaKind.folder && !beforeIds.contains(e.id))
        .toList(growable: false);

    if (!mounted) return;

    if (newItems.isNotEmpty) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TagAssignAfterImportPage(
            items: newItems,
            tagService: widget.tagService,
          ),
        ),
      );
    }

    _exitSelectMode();
    setState(() {});
  }

  Widget _buildGrid(
    List<MediaItem> items, {
    bool showFolderLabel = false,
    bool showPager = true,
    required Future<void> Function() onRefresh,
  }) {
    if (items.isEmpty) {
      return _buildRefreshableStatusBody(
        onRefresh: onRefresh,
        child: _buildEmptyBody(
          title: '該当するアイテムがありません',
          message: '引っ張って更新するか、別の条件を試してください。',
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: CustomScrollView(
        physics: _refreshScrollPhysics,
        cacheExtent: 200,
        slivers: [
          if (showPager && _galleryTotal > _pageSize)
            SliverToBoxAdapter(child: _buildPager()),
          SliverPadding(
            padding: const EdgeInsets.all(12),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.75,
              ),
              delegate: SliverChildBuilderDelegate((context, index) {
                final item = items[index];
                return _buildGridTile(
                  item,
                  showFolderLabel: showFolderLabel,
                  detailItemsSource: items,
                );
              }, childCount: items.length),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGridTile(
    MediaItem item, {
    required bool showFolderLabel,
    required List<MediaItem> detailItemsSource,
  }) {
    final isFavorite = _favorites.contains(item.id);
    final isSelected = _selectedIds.contains(item.id);

    return ControllerFocusable(
      debugLabel: 'gallery-tile-${item.id}',
      borderRadius: BorderRadius.circular(10),
      onLongPress: () {
        if (!_selectMode) {
          _enterSelectMode(item);
        } else {
          _toggleSelect(item);
        }
      },
      onPressed: () async {
        if (_selectMode) {
          _toggleSelect(item);
          return;
        }

        if (item.kind == MediaKind.folder) {
          _exitSelectMode();
          await _enterFolder(item);
          return;
        }

        final mediaOnly = detailItemsSource
            .where((entry) => entry.kind != MediaKind.folder)
            .toList(growable: false);
        final index = mediaOnly.indexWhere((entry) => entry.id == item.id);

        final changed = await Navigator.push<bool>(
          context,
          MaterialPageRoute(
            builder: (_) => ImageDetailPage(
              repo: widget.repo,
              tagService: widget.tagService,
              items: mediaOnly,
              initialIndex: index < 0 ? 0 : index,
              initialPdfPage: 1,
            ),
          ),
        );

        if (changed == true) {
          await _refreshVisibleContent();
          return;
        }

        await _refreshHomeShowcases();
      },
      child: _ThumbTile(
        repo: widget.repo,
        item: item,
        subtitle: showFolderLabel ? _folderLabelForItem(item) : null,
        isFavorite: isFavorite,
        onToggleFavorite: () => _toggleFavorite(item),
        selected: isSelected,
        folderTileMode: _folderTileMode,
        canRenameItem: !_selectMode && _canRenameItem(item),
        onRenameItem: () => _renameItemFromList(item),
        canDeleteItem: !_selectMode && _canDeleteItem(item),
        onDeleteItem: () => _deleteItemFromList(item),
      ),
    );
  }

  Widget _buildPager() {
    if (_galleryTotal <= _pageSize) return const SizedBox.shrink();

    final totalPages = (_galleryTotal + _pageSize - 1) ~/ _pageSize;
    final clamped = _galleryPageIndex.clamp(0, totalPages - 1);
    final start = clamped * _pageSize + 1;
    final end = ((clamped + 1) * _pageSize).clamp(0, _galleryTotal);
    final useDropdown = totalPages > 10;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Row(
        children: [
          Text('$start-$end / $_galleryTotal'),
          const Spacer(),
          if (useDropdown)
            DropdownButton<int>(
              value: clamped,
              items: List.generate(
                totalPages,
                (index) => DropdownMenuItem<int>(
                  value: index,
                  child: Text('ページ ${index + 1}'),
                ),
              ),
              onChanged: (value) {
                if (value == null) return;
                _loadGalleryPage(value);
              },
            )
          else
            Flexible(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: List.generate(totalPages, (index) {
                    final selected = index == clamped;
                    return Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: ChoiceChip(
                        label: Text('${index + 1}'),
                        selected: selected,
                        onSelected: (_) => _loadGalleryPage(index),
                      ),
                    );
                  }),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ThumbTile extends StatelessWidget {
  final MediaRepository repo;
  final MediaItem item;
  final String? subtitle;
  final bool isFavorite;
  final VoidCallback onToggleFavorite;
  final bool selected;
  final FolderTileMode folderTileMode;
  final bool canRenameItem;
  final VoidCallback? onRenameItem;
  final bool canDeleteItem;
  final VoidCallback? onDeleteItem;

  const _ThumbTile({
    required this.repo,
    required this.item,
    this.subtitle,
    required this.isFavorite,
    required this.onToggleFavorite,
    this.selected = false,
    required this.folderTileMode,
    this.canRenameItem = false,
    this.onRenameItem,
    this.canDeleteItem = false,
    this.onDeleteItem,
  });

  String get _displayTitle {
    return ItemNameService.formatMediaTitle(item.displayName, kind: item.kind);
  }

  @override
  Widget build(BuildContext context) {
    if (item.kind == MediaKind.folder) {
      if (folderTileMode == FolderTileMode.labelOnly) {
        return _buildFolderLabelTile(context);
      }
      return _buildFolderPreviewTile(context);
    }
    return _buildMediaTile(context);
  }

  Widget _buildFolderLabelTile(BuildContext context) {
    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(child: _buildFolderPlaceholder(context)),
          Positioned(
            top: 8,
            right: 8,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if ((canRenameItem && onRenameItem != null) ||
                    (canDeleteItem && onDeleteItem != null)) ...[
                  _buildDeleteMenuButton(),
                  const SizedBox(width: 4),
                ],
                const _FolderBadge(),
              ],
            ),
          ),
          Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: _TitleChip(title: _displayTitle, subtitle: subtitle),
          ),
          if (selected) _buildSelectionOverlay(),
        ],
      ),
    );
  }

  Widget _buildFolderPreviewTile(BuildContext context) {
    final galleryState = context
        .findAncestorStateOfType<_GalleryGridPageState>();
    final thumbsEnabled = galleryState?._thumbsEnabled ?? true;

    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(
            child: !thumbsEnabled
                ? _buildFolderPlaceholder(context)
                : FutureBuilder<Uint8List?>(
                    future: galleryState?._getFolderPreviewBytes(item),
                    builder: (context, snapshot) {
                      final bytes = snapshot.data;
                      if (bytes != null && bytes.isNotEmpty) {
                        return Image.memory(
                          bytes,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          filterQuality: FilterQuality.low,
                        );
                      }
                      return _buildFolderPlaceholder(context);
                    },
                  ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if ((canRenameItem && onRenameItem != null) ||
                    (canDeleteItem && onDeleteItem != null)) ...[
                  _buildDeleteMenuButton(),
                  const SizedBox(width: 4),
                ],
                const _FolderBadge(),
              ],
            ),
          ),
          Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: _TitleChip(title: _displayTitle, subtitle: subtitle),
          ),
          if (selected) _buildSelectionOverlay(),
        ],
      ),
    );
  }

  Widget _buildMediaTile(BuildContext context) {
    final galleryState = context
        .findAncestorStateOfType<_GalleryGridPageState>();
    final thumbsEnabled = galleryState?._thumbsEnabled ?? true;

    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(
            child: !thumbsEnabled
                ? const _TileShell(loading: true)
                : FutureBuilder<ThumbPair>(
                    future: repo.readThumbPair(item, maxWidth: 240),
                    builder: (context, snapshot) {
                      if (snapshot.hasError) {
                        return const _TileShell();
                      }
                      if (!snapshot.hasData) {
                        return const _TileShell(loading: true);
                      }
                      return _ThumbImage(bytes: snapshot.data!.front);
                    },
                  ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (item.kind == MediaKind.pdf) const _PdfBadge(),
                const SizedBox(width: 6),
                _FavButton(isFavorite: isFavorite, onPressed: onToggleFavorite),
                if ((canRenameItem && onRenameItem != null) ||
                    (canDeleteItem && onDeleteItem != null)) ...[
                  const SizedBox(width: 4),
                  _buildDeleteMenuButton(),
                ],
              ],
            ),
          ),
          Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: _TitleChip(title: _displayTitle, subtitle: subtitle),
          ),
          if (selected) _buildSelectionOverlay(),
        ],
      ),
    );
  }

  Widget _buildFolderPlaceholder(BuildContext context) {
    return Container(
      alignment: Alignment.center,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Icon(Icons.folder, size: 56),
    );
  }

  Widget _buildDeleteMenuButton() {
    return PopupMenuButton<_ThumbTileMenuAction>(
      tooltip: 'アイテムメニュー',
      padding: EdgeInsets.zero,
      icon: const Icon(Icons.more_vert, size: 18),
      onSelected: (action) {
        if (action == _ThumbTileMenuAction.renameItem) {
          onRenameItem!.call();
        }
        if (action == _ThumbTileMenuAction.deleteItem) {
          onDeleteItem!.call();
        }
      },
      itemBuilder: (context) => [
        if (canRenameItem && onRenameItem != null)
          const PopupMenuItem(
            value: _ThumbTileMenuAction.renameItem,
            child: ListTile(
              leading: Icon(Icons.edit_outlined),
              title: Text('名前を変更'),
            ),
          ),
        if (canDeleteItem && onDeleteItem != null)
          const PopupMenuItem(
            value: _ThumbTileMenuAction.deleteItem,
            child: ListTile(
              leading: Icon(Icons.delete_outline),
              title: Text('削除'),
            ),
          ),
      ],
    );
  }

  Widget _buildSelectionOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.35),
        alignment: Alignment.topRight,
        padding: const EdgeInsets.all(8),
        child: const Icon(Icons.check_circle, size: 26),
      ),
    );
  }
}

class _FavButton extends StatelessWidget {
  final bool isFavorite;
  final VoidCallback onPressed;

  const _FavButton({required this.isFavorite, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            isFavorite ? Icons.star : Icons.star_border,
            size: 18,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

class _PdfBadge extends StatelessWidget {
  const _PdfBadge();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.picture_as_pdf, size: 16, color: Colors.white),
            SizedBox(width: 4),
            Text('PDF', style: TextStyle(color: Colors.white)),
          ],
        ),
      ),
    );
  }
}

class _FolderBadge extends StatelessWidget {
  const _FolderBadge();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          'FOLDER',
          style: TextStyle(color: Colors.white, fontSize: 12),
        ),
      ),
    );
  }
}

class _TitleChip extends StatelessWidget {
  final String title;
  final String? subtitle;

  const _TitleChip({required this.title, this.subtitle});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: subtitle == null ? 2 : 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ThumbImage extends StatelessWidget {
  final Uint8List bytes;
  const _ThumbImage({required this.bytes});

  @override
  Widget build(BuildContext context) {
    return ColorFiltered(
      colorFilter: Theme.of(context).brightness == Brightness.dark
          ? const ColorFilter.matrix(<double>[
              0.85,
              0,
              0,
              0,
              0,
              0,
              0.85,
              0,
              0,
              0,
              0,
              0,
              0.85,
              0,
              0,
              0,
              0,
              0,
              1,
              0,
            ])
          : const ColorFilter.mode(Colors.transparent, BlendMode.dst),
      child: Image.memory(
        bytes,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        filterQuality: FilterQuality.low,
        errorBuilder: (context, error, stack) {
          return Container(
            alignment: Alignment.center,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.broken_image_outlined),
                const SizedBox(height: 6),
                Text(
                  'decode failed\nlen=${bytes.length}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 11),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _HomeShelfScroller extends StatefulWidget {
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  const _HomeShelfScroller({
    required this.itemCount,
    required this.itemBuilder,
  });

  @override
  State<_HomeShelfScroller> createState() => _HomeShelfScrollerState();
}

class _HomeShelfScrollerState extends State<_HomeShelfScroller> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 382,
      child: Scrollbar(
        controller: _controller,
        thumbVisibility: true,
        interactive: true,
        child: ListView.separated(
          controller: _controller,
          padding: const EdgeInsets.only(bottom: 14),
          scrollDirection: Axis.horizontal,
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: widget.itemCount,
          separatorBuilder: (_, _) => const SizedBox(width: 10),
          itemBuilder: widget.itemBuilder,
        ),
      ),
    );
  }
}

class _TileShell extends StatelessWidget {
  final bool loading;
  const _TileShell({this.loading = false});

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(10),
      child: Center(
        child: loading
            ? const CircularProgressIndicator()
            : const Icon(Icons.broken_image_outlined),
      ),
    );
  }
}

class _RouteBoundDialogHandle {
  BuildContext? _dialogContext;
  bool _closeRequested = false;

  Widget bind(BuildContext context, Widget child) {
    _dialogContext = context;
    if (_closeRequested) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        close();
      });
    }
    return child;
  }

  void close() {
    _closeRequested = true;
    final dialogContext = _dialogContext;
    if (dialogContext == null || !dialogContext.mounted) {
      return;
    }
    final navigator = Navigator.of(dialogContext);
    if (navigator.canPop()) {
      navigator.pop();
    }
    _dialogContext = null;
  }
}

class _PreparedImportSelection {
  final ImportSourceKind sourceKind;
  final List<MediaItem> items;
  final List<String> cleanupPaths;

  const _PreparedImportSelection({
    required this.sourceKind,
    required this.items,
    this.cleanupPaths = const <String>[],
  });
}
