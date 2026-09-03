import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, Platform;
import 'dart:typed_data';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/app_content_mode.dart';
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
import '../services/url_import_downloader_service.dart';
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
import 'xviewer_page.dart';
import 'widgets/scene_ui.dart';

part 'grid_gallery_models.dart';
part 'gallery_grid_view.dart';
part 'gallery_home_view.dart';
part 'gallery_import_actions.dart';
part 'gallery_thumbnail_cache.dart';
part 'gallery_search.dart';
part 'gallery_hitomi_search.dart';
part 'gallery_folder_actions.dart';

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
  final UrlImportDownloaderService _urlImportDownloaderService =
      UrlImportDownloaderService();
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
  bool _sidebarCollapsed = false;

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

  final LinkedHashMap<String, ThumbPair> _mediaThumbCache = LinkedHashMap();
  final Map<String, Future<ThumbPair>> _mediaThumbInFlight = {};
  int _mediaThumbCacheBytes = 0;
  int _mediaThumbActive = 0;
  int _visiblePrepareGeneration = 0;
  final List<Completer<void>> _mediaThumbWaiters = [];
  static const int _mediaThumbMaxWidth = 160;
  static const int _mediaThumbCacheMaxEntries = 240;
  static const int _mediaThumbCacheMaxBytes = 32 * 1024 * 1024;

  static const int _pageSize = 20;
  static const int _detailedBrowseRowsPerPage = 5;
  static const int _gallerySearchPageSize = 10;
  static const int _hitomiSearchPageSize = 10;
  int _galleryPageIndex = 0;
  int _galleryTotal = 0;
  int _gallerySearchPageIndex = 0;

  FolderTileMode _folderTileMode = FolderTileMode.labelOnly;
  int _detailedBrowseCardColumns = 3;
  MediaItem? _detailedBrowseSelectedItem;

  Set<String> _favorites = <String>{};
  Map<String, int> _ratingsById = <String, int>{};

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
  final FocusNode _homeSearchFocusNode = FocusNode();
  final TextEditingController _hitomiSearchCtrl = TextEditingController(
    text: 'orderby:popular orderbykey:week language:japanese',
  );
  final FocusNode _hitomiSearchFocusNode = FocusNode();
  Timer? _hitomiSuggestionDebounce;
  int _hitomiSuggestionLoadVersion = 0;
  List<HitomiSearchSuggestion> _hitomiRemoteSuggestions =
      const <HitomiSearchSuggestion>[];
  final Map<String, List<HitomiSearchSuggestion>> _hitomiSuggestionCache =
      <String, List<HitomiSearchSuggestion>>{};
  String _homeQuery = '';
  bool _homeSearching = false;
  List<MediaItem> _homeSearchResults = const [];
  List<MediaItem> _homeSearchCorpus = const [];
  Map<String, List<TagWithId>> _dbTagDetailsByItemId =
      <String, List<TagWithId>>{};
  String _homeSearchCorpusSignature = '';
  _SortMode _homeSearchSortMode = _SortMode.updatedAt;
  int? _homeRatingFilter;
  int _homeSearchPageIndex = 0;
  bool _hitomiSearching = false;
  List<HitomiSearchResult> _hitomiSearchResults = const <HitomiSearchResult>[];
  int _hitomiSearchPageIndex = 0;
  int _hitomiSearchTotal = 0;
  String? _hitomiSearchErrorMessage;
  int _hitomiSearchLoadVersion = 0;
  bool _hitomiInitialSearchStarted = false;
  Set<int> _hitomiImportedGalleryIds = <int>{};
  Set<String> _hitomiImportedTitleKeys = <String>{};
  Set<int> _hitomiSelectedGalleryIds = <int>{};
  Map<int, HitomiSearchResult> _hitomiSelectedResultsByGalleryId =
      <int, HitomiSearchResult>{};

  bool _shouldShowItem(MediaItem item) {
    if (item.kind == MediaKind.folder) {
      if (!AppContentModeConfig.isR18) return true;
      return item.displayName.trim().toLowerCase() != 'epub';
    }
    return AppContentModeConfig.isReader
        ? item.kind == MediaKind.epub
        : item.kind != MediaKind.epub;
  }

  List<MediaItem> _filterContentItems(List<MediaItem> items) {
    return items.where(_shouldShowItem).toList(growable: false);
  }

  Timer? _homeSearchDebounce;

  Map<String, List<String>> _dbTagsByItemId = <String, List<String>>{};

  final List<_FolderNavState> _dirStack = <_FolderNavState>[];

  bool get _canGoUp => _dirStack.isNotEmpty;

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
  int _homeRatingShelfRating = 5;
  List<MediaItem> _homeRatingShelfItems = const [];
  List<MediaItem> _homeRecentViewedItems = const [];
  List<MediaItem> _homeBookmarkedReadingItems = const [];
  Map<_HomeShelfKind, List<MediaItem>> _homeAllItemsByShelfKind =
      <_HomeShelfKind, List<MediaItem>>{};
  _HomeShelfKind _homeMyListKind = _HomeShelfKind.favorites;
  _HomeShelfKind? _homeDetailedBrowseMyListKind;
  Map<String, ReadingProgressEntry> _homeRecentViewEntriesByItemId =
      <String, ReadingProgressEntry>{};
  Map<String, ReadingProgressEntry> _readingProgressByItemId =
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
        _filterContentItems(
          (_folderItemsCacheRecursive[raw] ?? const <MediaItem>[])
              .where((item) => item.kind != MediaKind.folder)
              .toList(growable: false),
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
    _hitomiSearchCtrl.addListener(_handleHitomiSearchTextChanged);
    _loadPrefsAndAutoOpenFolder();
    unawaited(_initializeHostServerAndCheckVersion());
    _bindExternalSharePayloads();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reloadArtistTagMasters();
    });
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
                onPressed: () => Navigator.of(
                  dialogContext,
                ).pop(mismatch.hasUpdateUrl || mismatch.isHostOlder),
                child: Text(mismatch.hasUpdateUrl ? 'アップデート' : '確認'),
              ),
            ],
          );
        },
      );
      if (openUpdate == true) {
        final handled = mismatch.isHostOlder
            ? await _appVersionService.requestHostUpdate(
                widget.tagService.settings,
                mismatch,
              )
            : await _appVersionService.openUpdate(mismatch);
        if (!handled && mounted) {
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

  void _setHitomiRemoteSuggestions(List<HitomiSearchSuggestion> suggestions) {
    if (!mounted) {
      _hitomiRemoteSuggestions = suggestions;
      return;
    }
    setState(() {
      _hitomiRemoteSuggestions = suggestions;
    });
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
      final remoteFavoritesFuture = widget.tagService
          .listRemoteFavoriteIds()
          .catchError((_) => null);
      var favList =
          prefs.getStringList(_PrefsKeys.favorites) ?? const <String>[];
      var ratings = _decodeRatings(prefs.getString(_PrefsKeys.ratingsJson));
      final remoteRatingsFuture = widget.tagService
          .listRemoteRatings()
          .catchError((_) => null);
      final remoteFavorites = await remoteFavoritesFuture;
      final remoteRatings = await remoteRatingsFuture;
      if (remoteFavorites != null) {
        favList = remoteFavorites.toList(growable: false);
        await prefs.setStringList(_PrefsKeys.favorites, favList);
      }
      if (remoteRatings != null) {
        ratings = remoteRatings;
        await prefs.setString(_PrefsKeys.ratingsJson, jsonEncode(ratings));
      }
      _tagsById = <String, List<String>>{};
      _tagDetailsById = <String, List<TagWithId>>{};
      final fitIndex = prefs.getInt(_PrefsKeys.fitMode);
      final two = prefs.getBool(_PrefsKeys.twoPage);
      _sidebarCollapsed = prefs.getBool(_PrefsKeys.sidebarCollapsed) ?? false;
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
      final detailedColumns = prefs.getInt(
        _PrefsKeys.detailedBrowseCardColumns,
      );
      if (detailedColumns != null &&
          detailedColumns >= 1 &&
          detailedColumns <= 4) {
        _detailedBrowseCardColumns = detailedColumns;
      }
      await prefs.remove('prefs.detailedBrowseViewMode');
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
            _ratingsById = ratings;
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
          _ratingsById = ratings;
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
      final epubRaw = p.join(libRaw, 'epub');
      final epubDir = Directory(epubRaw);
      if (!await epubDir.exists()) {
        await epubDir.create(recursive: true);
      }
      final primaryRaw = AppContentModeConfig.isReader ? epubRaw : libRaw;
      if (!folders.contains(primaryRaw)) {
        folders = <String>[primaryRaw, ...folders];
        await prefs.setStringList(_PrefsKeys.folders, folders);
      }
      if (!aliases.containsKey(libRaw) || aliases[libRaw]!.trim().isEmpty) {
        aliases[libRaw] = '保管庫';
        aliasesUpdated = true;
      }
      if (!aliases.containsKey(epubRaw) || aliases[epubRaw]!.trim().isEmpty) {
        aliases[epubRaw] = 'EPUB';
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
      if (AppContentModeConfig.isReader) {
        existsFolders
          ..clear()
          ..add(primaryRaw);
      } else {
        existsFolders.remove(epubRaw);
      }
      if (current == null || !existsFolders.contains(current)) {
        if (existsFolders.contains(primaryRaw)) {
          current = primaryRaw;
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
      if (!folders.contains(primaryRaw)) {
        folders = List<String>.from(folders)..insert(0, primaryRaw);
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
        _ratingsById = ratings;
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
      final visibleFolder = _folder;
      if (visibleFolder != null) {
        await _loadFolder(
          visibleFolder,
          saveAsLast: false,
          pageIndex: _galleryPageIndex,
        );
      }
      await _reloadFavorites();
    }

    await _reloadRatings();
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
    return <Widget>[
      ...actions,
      if (_isWideLayout(context)) _buildSidebarToggleButton(),
      _buildRescanAppBarButton(),
    ];
  }

  Future<void> _saveFolderTileMode(FolderTileMode m) async {
    setState(() => _folderTileMode = m);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_PrefsKeys.folderTileMode, m.index);
  }

  Future<void> _saveDetailedBrowseCardColumns(int columns) async {
    if (columns < 1 || columns > 4) return;
    setState(() {
      _detailedBrowseCardColumns = columns;
      _homeSearchPageIndex = 0;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_PrefsKeys.detailedBrowseCardColumns, columns);
  }

  Map<String, int> _decodeRatings(String? raw) {
    if (raw == null || raw.isEmpty) return <String, int>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, int>{};
      final ratings = <String, int>{};
      for (final entry in decoded.entries) {
        final key = entry.key?.toString();
        final value = entry.value;
        final rating = value is int ? value : int.tryParse(value.toString());
        if (key == null || rating == null || rating < 3 || rating > 5) {
          continue;
        }
        ratings[key] = rating;
      }
      return ratings;
    } catch (_) {
      return <String, int>{};
    }
  }

  Future<void> _reloadRatings() async {
    final prefs = await SharedPreferences.getInstance();
    var ratings = _decodeRatings(prefs.getString(_PrefsKeys.ratingsJson));
    final remoteRatings = await widget.tagService
        .listRemoteRatings()
        .catchError((_) => null);
    if (remoteRatings != null) {
      ratings = remoteRatings;
      await prefs.setString(_PrefsKeys.ratingsJson, jsonEncode(ratings));
    }
    if (!mounted) return;
    setState(() => _ratingsById = ratings);
  }

  int? _ratingForItem(MediaItem item) {
    for (final variant in _idVariants(item.id)) {
      final rating = _ratingsById[variant];
      if (rating != null) return rating;
    }
    return null;
  }

  Future<void> _expandStableRatingsForItems(Iterable<MediaItem> items) async {
    final stableRatings = <String, int>{
      for (final entry in _ratingsById.entries)
        if (_looksLikeStableMediaId(entry.key)) entry.key: entry.value,
    };
    if (stableRatings.isEmpty) return;

    final expandedRatings = Map<String, int>.from(_ratingsById);
    for (final item in items) {
      if (item.kind == MediaKind.folder || _ratingForItem(item) != null) {
        continue;
      }
      try {
        final identity = await _homeMediaIdResolver.resolve(item);
        final rating = stableRatings[identity.stableId];
        if (rating == null) continue;
        for (final id in <String>{item.id, ...identity.aliases}) {
          for (final variant in _idVariants(id)) {
            expandedRatings[variant] = rating;
          }
        }
      } catch (_) {
        // Keep the existing path-based lookup when the ID cannot be resolved.
      }
    }

    if (!mounted || expandedRatings.length == _ratingsById.length) return;
    setState(() => _ratingsById = expandedRatings);
  }

  Future<void> _replaceRatingId(String oldId, String newId) async {
    final prefs = await SharedPreferences.getInstance();
    final ratings = _decodeRatings(prefs.getString(_PrefsKeys.ratingsJson));
    final rating = ratings.remove(oldId);
    if (rating == null) return;
    ratings[newId] = rating;
    await prefs.setString(_PrefsKeys.ratingsJson, jsonEncode(ratings));
    if (!mounted) return;
    setState(() => _ratingsById = ratings);
  }

  Future<void> _removeRatingsFromPrefs(Iterable<String> itemIds) async {
    final ids = itemIds.where((entry) => entry.trim().isNotEmpty).toSet();
    if (ids.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final ratings = _decodeRatings(prefs.getString(_PrefsKeys.ratingsJson));
    var changed = false;
    for (final id in ids) {
      changed = ratings.remove(id) != null || changed;
    }
    if (!changed) return;
    await prefs.setString(_PrefsKeys.ratingsJson, jsonEncode(ratings));
    if (!mounted) return;
    setState(() => _ratingsById = ratings);
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

  Future<void> _refreshCurrentPageReadingProgress([
    List<MediaItem>? source,
  ]) async {
    final targets = (source ?? _items)
        .where((item) => item.kind == MediaKind.pdf)
        .toList(growable: false);

    if (targets.isEmpty) {
      if (!mounted) return;
      setState(
        () => _readingProgressByItemId = <String, ReadingProgressEntry>{},
      );
      return;
    }

    try {
      final recentProgress = await _readingProgressService.fetchRecent(
        limit: 5000,
      );
      final itemByVariant = await _buildHomeItemLookup(targets, recentProgress);
      final progressByItemId = <String, ReadingProgressEntry>{};

      for (final entry in recentProgress) {
        final resolved =
            itemByVariant[entry.mediaId] ??
            itemByVariant[_readingProgressLookupKey(
              entry.folderRaw,
              entry.title,
            )];
        if (resolved == null) continue;

        progressByItemId[resolved.id] = entry;
        for (final variant in _idVariants(resolved.id)) {
          progressByItemId[variant] = entry;
        }
        final lookupKey = _readingProgressLookupKey(
          resolved.folderRaw,
          resolved.displayName,
        );
        if (lookupKey.isNotEmpty) {
          progressByItemId[lookupKey] = entry;
        }
      }

      if (!mounted) return;
      setState(() => _readingProgressByItemId = progressByItemId);
    } catch (error, stackTrace) {
      _logUiError('current-page-reading-progress', error, stackTrace);
    }
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

  // --------------------
  // --------------------

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

    final usesHostMetadata =
        widget.tagService.isRemoteMode || widget.tagService.isHostMode;
    final remoteId = await widget.tagService
        .setRemoteFavorite(item, !wasFavorite)
        .catchError((_) => null);
    if (usesHostMetadata && remoteId == null) return;
    if (wasFavorite) {
      next.removeAll(lookupIds);
      next.remove(remoteId);
    } else {
      next.add(remoteId ?? id);
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _PrefsKeys.favorites,
      next.toList(growable: false),
    );
    if (!mounted) return;
    setState(() {
      _favorites = next;
      if (wasFavorite) {
        _favoriteResolvedIds.removeAll(lookupIds);
      } else {
        _favoriteResolvedIds.addAll(lookupIds);
      }
    });
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
      await _replaceRatingId(item.id, updated.id);
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
      case MediaKind.epub:
        return 'EPUB';
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
    final epubCount = items.where((item) => item.kind == MediaKind.epub).length;
    final imageCount = items
        .where((item) => item.kind == MediaKind.image)
        .length;
    final folderCount = items
        .where((item) => item.kind == MediaKind.folder)
        .length;
    final summary = <String>[
      if (pdfCount > 0) 'PDF: $pdfCount件',
      if (epubCount > 0) 'EPUB: $epubCount件',
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
          final descendants = _filterContentItems(
            await widget.repo.listMediaRecursiveFiles(FolderHandle(item.id)),
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
      await _removeRatingsFromPrefs([
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

  // --------------------
  // --------------------

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

  @override
  void dispose() {
    _thumbResumeDebounce?.cancel();
    _homeSearchDebounce?.cancel();
    _hitomiSuggestionDebounce?.cancel();
    _externalShareSubscription?.cancel();
    _searchFocusNode
      ..removeListener(_handleGallerySearchFocusChange)
      ..dispose();
    _searchCtrl.dispose();
    _homeSearchCtrl.dispose();
    _homeSearchFocusNode.dispose();
    _hitomiSearchCtrl.removeListener(_handleHitomiSearchTextChanged);
    _hitomiSearchCtrl.dispose();
    _hitomiSearchFocusNode.dispose();
    super.dispose();
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
              _repoCapabilities.canRecursiveSearch ? 'PDF一覧' : 'PDF一覧（未対応）',
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

  // --- UI: responsive sidebar (Windows/desktop friendly) ---
  static const double _kSidebarWidth = SceneSpace.sidebarWidth;

  bool _isWideLayout(BuildContext context) =>
      MediaQuery.of(context).size.width >= 980;

  void _closeSidebar() {
    if (!_isWideLayout(context)) {
      Navigator.pop(context);
    }
  }

  Widget _withSidebar(BuildContext context, Widget body) {
    if (!_isWideLayout(context) || _sidebarCollapsed) return body;
    return Row(
      children: [
        SizedBox(width: _kSidebarWidth, child: _buildSidebarPanel()),
        const VerticalDivider(width: 1),
        Expanded(child: body),
      ],
    );
  }

  Future<void> _toggleSidebarCollapsed() async {
    final next = !_sidebarCollapsed;
    setState(() => _sidebarCollapsed = next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_PrefsKeys.sidebarCollapsed, next);
  }

  Widget _buildSidebarToggleButton() {
    return IconButton(
      tooltip: _sidebarCollapsed ? 'サイドパネルを表示' : 'サイドパネルを格納',
      onPressed: _toggleSidebarCollapsed,
      icon: Icon(_sidebarCollapsed ? Icons.menu_open : Icons.menu),
    );
  }

  Widget _sidebarHeader() =>
      const SceneSidebarHeader(title: '紙魚', subtitle: 'Library');

  Widget _sidebarSectionLabel(String text) => SceneSidebarSectionLabel(text);

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
            title: const Text('PDF一覧'),
            selected: _page == _MainPage.search,
            onTap: () async {
              _closeSidebar();
              _exitSelectMode();
              await _openDetailedBrowsePage();
            },
          ),
          ListTile(
            leading: const Icon(Icons.manage_search_outlined),
            title: const Text('検索'),
            selected: _page == _MainPage.hitomiSearch,
            onTap: () {
              _closeSidebar();
              _exitSelectMode();
              setState(() => _page = _MainPage.hitomiSearch);
            },
          ),
          ListTile(
            leading: const Icon(Icons.travel_explore_outlined),
            title: const Text('XViewer'),
            onTap: () async {
              _closeSidebar();
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => const XViewerPage(),
                ),
              );
            },
          ),
          const Divider(),
          _sidebarSectionLabel('ライブラリ'),
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text(
              _currentFolderRaw == null
                  ? 'フォルダ未選択'
                  : _folderLabel(_currentFolderRaw!),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text('${_foldersRaw.length} フォルダ'),
            onTap: () {
              _closeSidebar();
              _openLibrarySettings();
            },
          ),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('設定'),
            onTap: () {
              _closeSidebar();
              _openLibrarySettings();
            },
          ),
          if (false) ...[
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
        ],
      ),
    );
  }

  Future<void> _openLibrarySettings() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640),
          child: StatefulBuilder(
            builder: (context, setDialogState) => Padding(
              padding: const EdgeInsets.all(SceneSpace.x6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '設定',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        tooltip: '閉じる',
                        onPressed: () => Navigator.pop(dialogContext),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: SceneSpace.x4),
                  Text('閲覧', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: SceneSpace.x2),
                  DropdownButtonFormField<ReaderFitMode>(
                    value: _fitMode,
                    decoration: const InputDecoration(labelText: '表示フィット'),
                    items: const [
                      DropdownMenuItem(value: ReaderFitMode.vertical, child: Text('縦フィット')),
                      DropdownMenuItem(value: ReaderFitMode.horizontal, child: Text('横フィット')),
                      DropdownMenuItem(value: ReaderFitMode.contain, child: Text('全体表示 (Contain)')),
                    ],
                    onChanged: (value) async {
                      if (value == null) return;
                      setState(() => _fitMode = value);
                      setDialogState(() {});
                      await _saveFitMode(value);
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('見開き表示'),
                    value: _twoPage,
                    onChanged: (value) async {
                      setState(() => _twoPage = value);
                      setDialogState(() {});
                      await _saveTwoPage(value);
                    },
                  ),
                  const Divider(height: SceneSpace.x8),
                  Row(
                    children: [
                      Expanded(child: Text('ライブラリ', style: Theme.of(context).textTheme.titleMedium)),
                      IconButton(
                        tooltip: _primaryAddActionLabel,
                        onPressed: () async {
                          await _addFolder();
                          setDialogState(() {});
                        },
                        icon: Icon(_primaryAddActionIcon),
                      ),
                    ],
                  ),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final raw in _foldersRaw)
                          ListTile(
                            selected: raw == _currentFolderRaw,
                            leading: Icon(raw == _currentFolderRaw ? Icons.folder : Icons.folder_outlined),
                            title: Text(_folderLabel(raw), maxLines: 1, overflow: TextOverflow.ellipsis),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: '名前を変更',
                                  icon: const Icon(Icons.edit_outlined),
                                  onPressed: () async { await _renameFolder(raw); setDialogState(() {}); },
                                ),
                                IconButton(
                                  tooltip: '削除',
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () async { await _removeFolder(raw); setDialogState(() {}); },
                                ),
                              ],
                            ),
                            onTap: () async { await _switchFolder(raw); setDialogState(() {}); },
                          ),
                        if (_foldersRaw.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: SceneSpace.x4),
                            child: Text('登録フォルダがありません。右上の追加ボタンから登録してください。'),
                          ),
                      ],
                    ),
                  ),
                  const Divider(height: SceneSpace.x6),
                  Wrap(
                    spacing: SceneSpace.x2,
                    runSpacing: SceneSpace.x2,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () async {
                          await _openMetadataSettings();
                          setDialogState(() {});
                        },
                        icon: const Icon(Icons.tune_outlined, size: 18),
                        label: const Text('メタデータ設定'),
                      ),
                      if (widget.repo.canImportFromUrl)
                        FilledButton.icon(
                          onPressed: () async {
                            await _importUrlToLibrary();
                            setDialogState(() {});
                          },
                          icon: const Icon(Icons.download_outlined, size: 18),
                          label: const Text('URLから取り込み'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
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
            title: const Text('PDF一覧'),
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

    if (_page == _MainPage.hitomiSearch) {
      return ControllerNavigationRegion(
        key: const ValueKey<String>('hitomi-search'),
        debugLabel: 'hitomi-search',
        autofocusFirstFocusable: true,
        child: Scaffold(
          drawer: _isWideLayout(context) ? null : _buildSidebar(),
          appBar: AppBar(
            title: const Text('検索ページ'),
            actions: [if (_isWideLayout(context)) _buildSidebarToggleButton()],
          ),
          body: _wrapBodyWithUrlImportQueue(
            _withSidebar(
              context,
              _buildGuardedBody('hitomi-search-body', _buildHitomiSearchBody),
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
                                  DropdownMenuItem(
                                    value: _SortMode.unreadFirst,
                                    child: Text('未読'),
                                  ),
                                  DropdownMenuItem(
                                    value: _SortMode.readFirst,
                                    child: Text('既読'),
                                  ),
                                  DropdownMenuItem(
                                    value: _SortMode.bookmarkedFirst,
                                    child: Text('しおり'),
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
}
