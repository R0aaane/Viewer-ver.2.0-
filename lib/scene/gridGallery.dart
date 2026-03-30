import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, Platform;
import 'dart:typed_data';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../database/tag_service.dart';
import '../models/folder.dart';
import '../models/mediaItem.dart';
import '../models/tag.dart';
import '../database/pdf_export_service.dart';
import '../services/host_api_server_service.dart';
import '../services/import_tag_rule_service.dart';
import 'import_to_host_dialog.dart';
import 'tag_assign_after_import.dart';

import '../repository/mediaRepository.dart';

import 'artistTagIndex.dart';
import 'detailImage.dart';
import 'metadata_settings_dialog.dart';
import 'url_import_dialog.dart';

enum _SortMode { name, updatedAt, addedAt }

enum _MainPage { home, gallery, search }

enum _HomeMenuAction {
  addFolder,
  importToLibrary,
  importUrlToLibrary,
  artistTagIndex,
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
  folderTileMode,
  metadataSettings,
  goHome,
}

enum FolderTileMode {
  labelOnly,
  preview,
}

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
  completed,
  empty,
  failed,
}

enum _RegisteredFolderRemovalAction {
  unregisterOnly,
  deleteFiles,
}

enum _ThumbTileMenuAction { deletePdf }

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
      if (oldestVal != null) _folderPreviewCacheBytes -= oldestVal.lengthInBytes;
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

  Timer? _homeSearchDebounce;

  Map<String, List<String>> _dbTagsByItemId = <String, List<String>>{};

  final List<_FolderNavState> _dirStack = <_FolderNavState>[];

  bool get _canGoUp => _dirStack.isNotEmpty;
  

  Future<void> _enterFolder(MediaItem folderItem) async { 
    if (_folder == null) return;  

    _dirStack.add(_FolderNavState(_folder!, _galleryPageIndex));

    await _loadFolder(FolderHandle(folderItem.id), saveAsLast: false, pageIndex: 0);
  }

  Future<void> _goUpFolder() async {
    if (_dirStack.isEmpty) return;
    final prev = _dirStack.removeLast();

    await _loadFolder(prev.folder, saveAsLast: false, pageIndex: prev.pageIndex);
  }

  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  _SortMode _sortMode = _SortMode.name;

  Map<String, String> _folderAliases = <String, String>{};

  final Map<String, List<MediaItem>> _folderItemsCache = {};
  List<MediaItem> _favoriteItemsAll = const [];
  bool _loadingFavAll = false;

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
          _folderItemsCacheRecursive[raw] = await widget.repo.listMediaRecursiveFiles(
            FolderHandle(raw),
          );
        } catch (_) {
          _folderItemsCacheRecursive[raw] = const <MediaItem>[];
        }
      }

      all.addAll(
        (_folderItemsCacheRecursive[raw] ?? const <MediaItem>[])
            .where((item) => item.kind != MediaKind.folder),
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
    Navigator.pop(context);

    _exitSelectMode();
    setState(() {
      _page = _MainPage.search;
      _homeQuery = '#$tagName';
      _homeSearchCtrl.text = '#$tagName';
    });

    await _runHomeSearch();
  }

  @override
  void initState() {
    super.initState();
    _loadPrefsAndAutoOpenFolder();
    unawaited(_initializeHostServerIfNeeded());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reloadArtistTagMasters();
    });
  }

  Future<void> _initializeHostServerIfNeeded() async {
    await widget.hostServerService.refresh();
    final settings = widget.tagService.settings;
    if (settings.isHostMode && settings.autoStartHostServer) {
      await widget.hostServerService.startServer(tagService: widget.tagService);
    }
  }

  void _logUiError(String label, Object error, StackTrace stackTrace) {
    debugPrint('[GalleryGridPage][$label] $error');
    debugPrintStack(label: '[GalleryGridPage][$label]', stackTrace: stackTrace);
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
                      Icon(
                        icon,
                        size: 40,
                        color: theme.colorScheme.primary,
                      ),
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
                    FilledButton(
                      onPressed: onAction,
                      child: Text(actionLabel),
                    ),
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(message)),
          );
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
        if (current == null) return;
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
        await prefs.setString(_PrefsKeys.folderAliasesJson, jsonEncode(aliases));
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
      if (current == null) return;
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } finally {
      if (mounted) {
        setState(() => _initializing = false);
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

    if (_homeQuery.trim().isNotEmpty) {
      _folderItemsCacheRecursive.clear();
      await _runHomeSearch();
    } else if (mounted && _page == _MainPage.search) {
      setState(() {
        _homeSearching = false;
        _homeSearchResults = const <MediaItem>[];
        _homeSearchErrorMessage = null;
      });
    }

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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('スタンドアロンモードでは再スキャンは不要です')),
      );
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
      _buildRescanAppBarButton(),
    ];
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

  List<String> _tagsFor(MediaItem item) => _tagsById[item.id] ?? const <String>[];

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

  Future<void> _reloadTags() async {
    await _refreshCurrentPageTags();
  }

  bool _matchHomeQuery(MediaItem item, String qRaw) {
    final q = qRaw.trim().toLowerCase();
    if (q.isEmpty) return true;

    final tokens = q.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
    final name = item.displayName.toLowerCase();

    final tags =
        (_dbTagsByItemId[item.id] ??
                _dbTagsByItemId[item.id.toLowerCase()] ??
                _dbTagsByItemId[item.id.replaceAll('/', '\\')] ??
                _dbTagsByItemId[item.id.replaceAll('\\', '/')] ??
                const <String>[])
            .map((e) => e.toLowerCase())
            .toList(growable: false);

    bool matchToken(String t) {
      if (t == 'untagged' || t == '未分類') {
        return true;
      }
      if (t.contains(':')) {
        final idx = t.indexOf(':');
        final key = t.substring(0, idx);
        if (key == 'artist' ||
            key == 'series' ||
            key == 'type' ||
            key == 'character' ||
            key == 'free') {
          return true;
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

  Future<void> _runHomeSearch() async {
    final q = _homeQuery.trim();
    if (!_repoCapabilities.canRecursiveSearch) {
      if (!mounted) return;
      setState(() {
        _homeSearching = false;
        _homeSearchResults = const [];
        _homeSearchErrorMessage = null;
      });
      return;
    }

    if (q.isEmpty) {
      if (!mounted) return;
      setState(() {
        _homeSearching = false;
        _homeSearchResults = const [];
        _homeSearchErrorMessage = null;
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      _homeSearching = true;
      _homeSearchErrorMessage = null;
    });

    try {
      for (final raw in _foldersRaw) {
        if (_folderItemsCacheRecursive.containsKey(raw)) continue;
        try {
          final list = await widget.repo.listMediaRecursiveFiles(FolderHandle(raw));
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

      widget.tagService.rememberItems(all);
      final rawMap = await widget.tagService.getTagNamesByItems(all);

      final expanded = <String, List<String>>{};
      rawMap.forEach((k, v) {
        for (final vv in _idVariants(k)) {
          expanded[vv] = v;
        }
      });

      _dbTagsByItemId = expanded;

      final tokens = q
          .toLowerCase()
          .split(RegExp(r'\s+'))
          .where((entry) => entry.isNotEmpty)
          .toList(growable: false);

      String? artist;
      String? series;
      bool onlyUntagged = false;
      final extraCategoryFilters = <MapEntry<TagCategory, String>>[];

      for (final token in tokens) {
        if (token == 'untagged' || token == '未分類') {
          onlyUntagged = true;
          continue;
        }
        final idx = token.indexOf(':');
        if (idx <= 0 || idx == token.length - 1) {
          continue;
        }

        final key = token.substring(0, idx);
        final value = token.substring(idx + 1).trim();
        if (value.isEmpty) {
          continue;
        }

        switch (key) {
          case 'artist':
            artist = value;
            break;
          case 'series':
            series = value;
            break;
          case 'type':
            extraCategoryFilters.add(MapEntry(TagCategory.mediaType, value));
            break;
          case 'character':
            extraCategoryFilters.add(MapEntry(TagCategory.character, value));
            break;
          case 'free':
            extraCategoryFilters.add(MapEntry(TagCategory.free, value));
            break;
        }
      }

      Set<String>? matchedIds;
      if (artist != null || series != null) {
        matchedIds = (await widget.tagService.findItemIdsByArtistSeriesInCandidates(
          candidates: all,
          artist: artist,
          series: series,
        ))
            .toSet();
      }

      for (final filter in extraCategoryFilters) {
        final ids = await widget.tagService.findItemIdsByTag(
          folderRaw: '',
          category: filter.key,
          name: filter.value,
          partial: true,
          candidates: all,
        );
        matchedIds = matchedIds == null ? ids.toSet() : matchedIds.intersection(ids.toSet());
      }

      if (onlyUntagged) {
        final ids = await widget.tagService.findUntaggedItemIdsInCandidates(all);
        matchedIds = matchedIds == null ? ids.toSet() : matchedIds.intersection(ids.toSet());
      }

      final filtered = all
          .where((item) => matchedIds == null || matchedIds.contains(item.id))
          .where((item) => _matchHomeQuery(item, q))
          .toList(growable: false);

      final sorted = filtered.toList(growable: true)
        ..sort(
          (a, b) => a.displayName.toLowerCase().compareTo(
            b.displayName.toLowerCase(),
          ),
        );

      if (!mounted) return;
      setState(() {
        _homeSearching = false;
        _homeSearchResults = sorted.take(50).toList(growable: false);
        _homeSearchErrorMessage = null;
      });
    } catch (e, st) {
      _logUiError('home-search', e, st);

      if (!mounted) return;
      setState(() {
        _homeSearching = false;
        _homeSearchResults = const [];
        _homeSearchErrorMessage = 'ホーム検索でエラーが発生しました: $e';
      });

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('ホーム検索でエラー: $e')));
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

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('ライブラリ整理完了: 移動 ${moved.length} 件')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('ライブラリ整理に失敗しました: $e')));
    }
  }

  Widget _homeFavThumb(MediaItem item) {
    return AspectRatio(
      aspectRatio: 3 / 4,
      child: ClipRRect(
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
      ),
    );
  }

  Widget _buildHomeBody() {
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

    final folderCount = _foldersRaw.length;
    final currentLabel = _currentFolderRaw == null
        ? '未選択'
        : _folderLabel(_currentFolderRaw!);

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
                  '検索（全フォルダ）',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 44,
                  child: TextField(
                    controller: _homeSearchCtrl,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: 'タイトル / #タグ / artist:xxx / series:yyy',
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
                                _runHomeSearch();
                              },
                            ),
                    ),
                    onChanged: (v) {
                      setState(() => _homeQuery = v);

                      _homeSearchDebounce?.cancel();
                      _homeSearchDebounce = Timer(
                        const Duration(milliseconds: 250),
                        () {
                          if (!mounted) return;
                          _runHomeSearch();
                        },
                      );
                    },
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
                  const Text('検索ワードを入力してください。')
                else if (_homeSearchResults.isEmpty)
                  const Text('該当なし')
                else ...[
                  Text('件数: ${_homeSearchResults.length} 件（最大50件表示）'),
                  const SizedBox(height: 8),
                  ..._homeSearchResults.map((item) {
                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      child: InkWell(
                        onTap: () => _openDetailFromHome(item),
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(height: 96, child: _homeFavThumb(item)),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.displayName,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleMedium,
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      item.kind == MediaKind.pdf ? 'PDF' : '画像',
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
                  '概要',
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
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'お気に入り（全フォルダ）',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                if (_loadingFavAll)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_favoriteItemsAll.isEmpty)
                  const Text('お気に入りはまだありません。')
                else ...[
                  Text('件数: ${_favoriteItemsAll.length}'),
                  const SizedBox(height: 8),
                  ..._favoriteItemsAll.take(10).map((item) {
                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      child: InkWell(
                        onTap: () => _openDetailFromHome(item),
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                height: 120,
                                child: _homeFavThumb(item),
                              ),

                              const SizedBox(width: 12),

                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.displayName,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleMedium,
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      item.kind == MediaKind.pdf ? 'PDF' : '画像',
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
                  '登録フォルダ',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                if (_foldersRaw.isEmpty)
                  Text(
                    '登録フォルダがありません。「$_primaryAddActionLabel」から追加してください。',
                  )
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

    if (_homeSearching) {
      return _buildRefreshableStatusBody(
        onRefresh: _handlePullToRefresh,
        child: _buildLoadingBody(
          title: '検索中です',
          message: '全フォルダを検索しています。',
        ),
      );
    }

    if (_homeSearchErrorMessage != null) {
      return _buildRefreshableStatusBody(
        onRefresh: _handlePullToRefresh,
        child: _buildErrorBody(
          title: '検索に失敗しました',
          message: _homeSearchErrorMessage!,
          onAction: _runHomeSearch,
        ),
      );
    }

    final q = _homeQuery.trim();
    if (q.isEmpty) {
      return _buildRefreshableStatusBody(
        onRefresh: _handlePullToRefresh,
        child: _buildEmptyBody(
          title: 'キーワードを入力してください',
          message: 'Home の検索欄にキーワード、タグ、#tag を入力してください。',
        ),
      );
    }

    if (_homeSearchResults.isEmpty) {
      return _buildRefreshableStatusBody(
        onRefresh: _handlePullToRefresh,
        child: _buildEmptyBody(
          title: '該当するアイテムがありません',
          message: '別のキーワード、タグ、artist / series 指定を試してください。',
        ),
      );
    }

    return _buildGridFromList(
      _homeSearchResults,
      showFolderLabel: true,
      onRefresh: _handlePullToRefresh,
    );
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
      } catch (_) {
      }
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

  String _folderLabel(String raw) {
    final a = _folderAliases[raw];
    final sanitized = a == null ? null : _sanitizeFolderAlias(a, fallbackRaw: raw);
    if (sanitized != null && sanitized.trim().isNotEmpty) return sanitized.trim();
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
    final result = await showDialog<String>(
      context: context,
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
    final favList =
        prefs.getStringList(_PrefsKeys.favorites) ?? const <String>[];
    if (!mounted) return;
    setState(() => _favorites = favList.toSet());
  }

  Future<void> _toggleFavorite(MediaItem item) async {
    final id = item.id;

    final next = Set<String>.from(_favorites);
    if (next.contains(id)) {
      next.remove(id);
    } else {
      next.add(id);
    }

    setState(() => _favorites = next);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _PrefsKeys.favorites,
      next.toList(growable: false),
    );
    await _refreshAllFavoritesItems();
  }

  Future<void> _openDetailFromHome(MediaItem item) async {
    final folderRaw = item.folderRaw;

    if (!_foldersRaw.contains(folderRaw)) {
      final next = List<String>.from(_foldersRaw)..add(folderRaw);
      setState(() {
        _foldersRaw = next;
        _currentFolderRaw = folderRaw;
      });

      await _persistFolders();
    } else {
      if (_currentFolderRaw != folderRaw) {
        setState(() {
          _currentFolderRaw = folderRaw;
          _folder = FolderHandle(folderRaw);
        });
        await _persistFolders();
      }
    }

    if (_folderItemsCache.containsKey(folderRaw)) {
      setState(() {
        _items = _folderItemsCache[folderRaw] ?? const [];
        _folder = FolderHandle(folderRaw);
        _galleryLoadErrorMessage = null;
      });
    } else {
      await _loadFolder(FolderHandle(folderRaw), saveAsLast: false);
      _folderItemsCache[folderRaw] = _items;
    }

    final idx = _items.indexWhere((e) => e.id == item.id);
    if (idx < 0) {
      if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ファイルが見つかりません。移動または削除された可能性があります。')),
        );
      return;
    }

    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ImageDetailPage(
          repo: widget.repo,
          tagService: widget.tagService,
          items: _items,
          initialIndex: idx,
          initialPdfPage: 1,
        ),
      ),
    );

    if (changed == true) {
      await _refreshVisibleContent();
    }
  }

  bool _canDeletePdfItem(MediaItem item) {
    return item.kind == MediaKind.pdf && _repoCapabilities.canDelete;
  }

  Future<bool> _confirmPdfDeletion(MediaItem item) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('この PDF を削除しますか？'),
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

  Future<void> _removeFavoriteFromPrefs(String itemId) async {
    final prefs = await SharedPreferences.getInstance();
    final next = (prefs.getStringList(_PrefsKeys.favorites) ?? const <String>[])
        .toSet();
    next.remove(itemId);
    await prefs.setStringList(
      _PrefsKeys.favorites,
      next.toList(growable: false),
    );
    if (!mounted) return;
    setState(() => _favorites = next);
  }

  Future<void> _deletePdfFromList(MediaItem item) async {
    if (!_canDeletePdfItem(item)) {
      return;
    }

    final confirmed = await _confirmPdfDeletion(item);
    if (!confirmed || !mounted) {
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    try {
      final deleted = await widget.repo.deleteItem(item);
      if (!deleted) {
        messenger.showSnackBar(
          const SnackBar(content: Text('PDF の削除に失敗しました')),
        );
        return;
      }

      String? metadataWarning;
      try {
        await widget.tagService.handleDeletedItems([item]);
      } catch (error) {
        metadataWarning = 'メタデータ削除に失敗しました: $error';
      }

      await _removeFavoriteFromPrefs(item.id);
      if (!mounted) return;

      setState(() {
        _selectedIds.remove(item.id);
      });

      await _refreshVisibleContent();
      if (!mounted) return;

      messenger.showSnackBar(
        SnackBar(content: Text('「${item.displayName}」を削除しました')),
      );
      if (metadataWarning != null) {
        messenger.showSnackBar(SnackBar(content: Text(metadataWarning)));
      }
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('PDF の削除に失敗しました: $error')),
      );
    }
  }

  String _folderLabelForItem(MediaItem item) {
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

    final parentRaw = _parentDirOfFullPath(item.id);
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
    } catch (e, st) {
      _logUiError('load-folder', e, st);
      final message = 'フォルダの読み込みに失敗しました: $e';
      if (!mounted) return;
      setState(() {
        _loading = false;
        _galleryLoadErrorMessage = message;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
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
    } catch (e, st) {
      _logUiError('load-gallery-page', e, st);
      final message = 'ページの読み込みに失敗しました: $e';
      if (!mounted) return;
      setState(() {
        _loading = false;
        _galleryLoadErrorMessage = message;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
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

    final request = await ImportToHostDialog.show(
      context,
      tagService: widget.tagService,
    );
    if (request == null) {
      return;
    }

    final progress = ValueNotifier<MediaTransferProgress?>(null);
    var dialogShown = false;

    try {
      final lib = await widget.repo.getAppLibraryFolder();
      final libRaw = lib.raw;
      if (!_foldersRaw.contains(libRaw)) {
        setState(() {
          _foldersRaw = <String>[libRaw, ..._foldersRaw];
        });
      }

      dialogShown = true;
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => AlertDialog(
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
      );

      final importedCount = await widget.repo.importIntoFolder(
        lib,
        request: request,
        onProgress: (next) => progress.value = next,
      );
      if (!mounted) return;

      if (importedCount <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('取り込み対象がありませんでした')),
        );
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
        if (_homeQuery.trim().isNotEmpty) {
          await _runHomeSearch();
        }
        await _refreshCurrentPageTags();
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
      if (dialogShown &&
          mounted &&
          Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('フォルダ本体の削除に失敗しました')),
        );
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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
    if (_homeQuery.trim().isNotEmpty) {
      await _runHomeSearch();
    }
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
    return showDialog<_RegisteredFolderRemovalAction>(
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
              const Text(
                '登録のみ解除するのか、フォルダ本体と実ファイルまで削除するのかを確認してから実行してください。',
              ),
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
                const Text(
                  'このフォルダでは実ファイル削除は使えないため、登録解除のみ行えます。',
                ),
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
    if (_currentFolderRaw == null) return;
    final folder = FolderHandle(_currentFolderRaw!);
    final progress = ValueNotifier<MediaTransferProgress?>(null);
    var dialogShown = false;
    try {
      dialogShown = true;
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => AlertDialog(
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
      );
      final count = await widget.repo.importIntoFolder(
        folder,
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
      if (dialogShown && mounted && Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
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

      dialogShown = true;
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => AlertDialog(
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
      );

      final importedCount = await widget.repo.importIntoFolder(
        lib,
        onProgress: (next) => progress.value = next,
      );
      if (!mounted) return;

      if (importedCount <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('取り込み対象がありませんでした')),
        );
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

      if (_homeQuery.trim().isNotEmpty) {
        await _runHomeSearch();
      }
      await _refreshCurrentPageTags();
      await _refreshArtistTagCounts();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ライブラリへ取り込み: $importedCount 件・タグ付け対象: ${newItems.length} 件')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ライブラリ取り込みに失敗しました: $e')),
      );
    } finally {
      progress.dispose();
      if (dialogShown && mounted && Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
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
    if (_currentFolderRaw == null) return;

    await _runUrlImport(
      folder: FolderHandle(_currentFolderRaw!),
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
  }) async {
    final importRequest = await UrlImportDialog.show(
      context,
      title: dialogTitle,
      description: dialogDescription,
    );
    if (importRequest == null || !importRequest.hasAnySource) {
      return;
    }

    Set<String> beforeItemIds = const <String>{};
    if (!widget.repo.isRemoteMode) {
      try {
        final beforeItems = await widget.repo.listMediaRecursiveFiles(folder);
        beforeItemIds = beforeItems
            .where((item) => item.kind != MediaKind.folder)
            .map((item) => item.id)
            .toSet();
      } catch (error) {
        debugPrint('[url-import] failed to snapshot current items: $error');
      }
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

      if (!result.hasChanges) {
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
      if (!widget.repo.isRemoteMode) {
        inferredTaggedCount = await _applyInferredTagsToImportedItems(
          folder: folder,
          beforeItemIds: beforeItemIds,
          sourceUrl: importRequest.sourceUrl,
          options: importRequest.options,
        );
      }

      _folderItemsCache.clear();
      _folderItemsCacheRecursive.clear();
      _dirStack.clear();

      if (activateFolder) {
        setState(() {
          _currentFolderRaw = folder.raw;
          _folder = folder;
          _page = _MainPage.gallery;
        });
        await _persistFolders();
      }

      await _loadFolder(folder, saveAsLast: false);
      if (!mounted) return;

      if (_homeQuery.trim().isNotEmpty) {
        await _runHomeSearch();
      }
      await _refreshCurrentPageTags();
      await _refreshArtistTagCounts();

      final parts = <String>[
        '${result.importedCount} 件',
        if (inferredTaggedCount > 0) 'タグ ${inferredTaggedCount} 件',
        if (result.skippedCount > 0) 'スキップ ${result.skippedCount} 件',
        if (result.failedCount > 0) '失敗 ${result.failedCount} 件',
      ];
      final message = '$successLabel: ${parts.join(' / ')}';
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
      if (!mounted) return;
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

  Future<int> _applyInferredTagsToImportedItems({
    required FolderHandle folder,
    required Set<String> beforeItemIds,
    required String sourceUrl,
    required UrlImportOptions options,
  }) async {
    try {
      final afterItems = await widget.repo.listMediaRecursiveFiles(folder);
      final sourceUrls = options.collectSourceUrls(sourceUrl);
      var taggedCount = 0;

      for (final item in afterItems) {
        if (item.kind == MediaKind.folder || beforeItemIds.contains(item.id)) {
          continue;
        }
        if (item.kind != MediaKind.pdf) {
          continue;
        }

        try {
          final inferred = ImportTagRuleService.inferForImportedItem(
            itemPath: item.id,
            rootFolderRaw: folder.raw,
            displayName: item.displayName,
            sourceUrls: sourceUrls,
          );
          final hitomiPdfTags = _filterHitomiPdfAutoTags(inferred.tags);
          if (hitomiPdfTags.isEmpty) {
            continue;
          }

          await widget.tagService.addTagsToItem(item, hitomiPdfTags);
          taggedCount++;
          debugPrint(
            '[url-import] inferred tags for ${item.displayName}: '
            '${hitomiPdfTags.map((tag) => '${tag.category.name}:${tag.name}').join(', ')} '
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
      for (final raw in _foldersRaw) {
        final items = _folderItemsCache[raw] ?? const <MediaItem>[];
        all.addAll(items.where((e) => _favorites.contains(e.id)));
      }

      if (!mounted) return;
      setState(() => _favoriteItemsAll = all.toList(growable: false));
    } finally {
      if (mounted) setState(() => _loadingFavAll = false);
    }
  }

  @override
  void dispose() {
    _thumbResumeDebounce?.cancel();
    _homeSearchDebounce?.cancel();
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
        out = out.where((e) => e.kind == MediaKind.folder || e.kind == MediaKind.pdf);
      } else {
        out = out.where((e) => e.kind == MediaKind.folder || e.kind == MediaKind.image);
      }
    }

    final qRaw = _query.trim().toLowerCase();
    if (qRaw.isNotEmpty) {
      final tokens = qRaw.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();

      out = out.where((item) {
        final name = item.displayName.toLowerCase();
        final tags = _tagsFor(item).map((e) => e.toLowerCase()).toList(growable: false);
        final detailedTags = _tagDetailsById[item.id] ?? const <TagWithId>[];

        bool matchToken(String t) {
          if (t == 'untagged' || t == '未分類') {
            return detailedTags.isEmpty;
          }

          final separator = t.indexOf(':');
          if (separator > 0 && separator < t.length - 1) {
            final key = t.substring(0, separator);
            final value = t.substring(separator + 1);

            TagCategory? category;
            switch (key) {
              case 'artist':
                category = TagCategory.artist;
                break;
              case 'series':
                category = TagCategory.series;
                break;
              case 'type':
                category = TagCategory.mediaType;
                break;
              case 'character':
                category = TagCategory.character;
                break;
              case 'free':
                category = TagCategory.free;
                break;
            }

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
        .where((item) => (_tagDetailsById[item.id] ?? const <TagWithId>[]).isEmpty)
        .toList(growable: false);
  }

  Future<void> _openMetadataSettings() async {
    final changed = await MetadataSettingsDialog.show(
      context,
      tagService: widget.tagService,
      hostServerService: widget.hostServerService,
    );
    if (changed != true || !mounted) return;
    await widget.repo.reloadSettings();
    await widget.hostServerService.refresh();
    final nextSettings = widget.tagService.settings;
    if (!nextSettings.isHostMode &&
        widget.hostServerService.status.state == HostServerState.running) {
      await widget.hostServerService.stopServer();
    } else if (nextSettings.isHostMode && nextSettings.autoStartHostServer) {
      await widget.hostServerService.startServer(tagService: widget.tagService);
    }
    _folderItemsCache.clear();
    _folderItemsCacheRecursive.clear();
    _dirStack.clear();
    await _loadPrefsAndAutoOpenFolder();
    await _refreshCurrentPageTags();
    if (_homeQuery.trim().isNotEmpty) {
      await _runHomeSearch();
    }
    await _reloadArtistTagMasters();
    if (mounted) {
      setState(() {});
    }
  }
  // ---- AppBar overflow menus ----
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
      case _HomeMenuAction.metadataSettings:
        await _openMetadataSettings();
        return;
      case _HomeMenuAction.refreshFavorites:
        _refreshAllFavoritesItems();
        return;
      case _HomeMenuAction.openSearchGallery:
        _exitSelectMode();
        setState(() => _page = _MainPage.search);
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
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('このモードではライブラリ整理は未対応です')),
          );
          return;
        }
        _organizeLibrary();
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
                _repoCapabilities.canUpload
                    ? 'ライブラリへ取り込み'
                    : 'ライブラリへ取り込み（未対応）',
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
          value: _HomeMenuAction.metadataSettings,
          child: ListTile(
            leading: Icon(Icons.settings_outlined),
            title: Text('動作モード設定'),
          ),
        ),
        const PopupMenuItem(
          value: _HomeMenuAction.refreshFavorites,
          child: ListTile(
            leading: Icon(Icons.star),
            title: Text('お気に入り更新'),
          ),
        ),
        PopupMenuItem(
          value: _HomeMenuAction.openSearchGallery,
          enabled: _repoCapabilities.canRecursiveSearch,
          child: ListTile(
            leading: Icon(Icons.grid_view),
            title: Text(
              _repoCapabilities.canRecursiveSearch
                  ? '検索結果（ギャラリー表示）'
                  : '検索結果（ギャラリー表示）（未対応）',
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

    final images = _applyFilter(_items, pdfOnly: false)
        .where((item) => item.kind == MediaKind.image)
        .toList(growable: false);
    if (images.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('画像がありません')),
      );
      return;
    }

    final folderName = _currentFolderRaw == null
        ? 'export'
        : _folderLabel(_currentFolderRaw!);

    int done = 0;
    final total = images.length;

    showDialog(
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('保存をキャンセルしました')),
        );
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('PDF 出力に失敗しました: $e')));
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
      debugPrint('[pdf-export] skipped post-process: generated item not addressable');
      return const _GeneratedPdfPostProcessResult();
    }

    final sourceFolderRaw = _currentFolderRaw ??
        (sourceImages.isNotEmpty ? sourceImages.first.folderRaw : item.folderRaw);

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
        final isImportSourceMediaType = tag.category == TagCategory.mediaType &&
            tag.name.toLowerCase() == 'hitomi';
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

  List<Tag> _filterHitomiPdfAutoTags(Iterable<Tag> tags) {
    final out = <Tag>[];
    final seen = <String>{};
    var hasHitomiMediaType = false;

    for (final tag in tags) {
      final normalizedName = tag.name.trim();
      if (normalizedName.isEmpty) {
        continue;
      }

      final isArtist = tag.category == TagCategory.artist;
      final isHitomiMediaType = tag.category == TagCategory.mediaType &&
          normalizedName.toLowerCase() == 'hitomi';
      if (!isArtist && !isHitomiMediaType) {
        continue;
      }

      if (isHitomiMediaType) {
        hasHitomiMediaType = true;
      }

      final key = '${tag.category.name}\u0000${normalizedName.toLowerCase()}';
      if (!seen.add(key)) {
        continue;
      }
      out.add(Tag(name: normalizedName, category: tag.category));
    }

    if (!hasHitomiMediaType) {
      return const <Tag>[];
    }
    return out;
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
    final mode = await showDialog<FolderTileMode>(
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
          Text('現在のフォルダ: ${currentLabel}',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _sidebarSectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Text(
        text,
        style: Theme.of(context)
            .textTheme
            .labelLarge
            ?.copyWith(color: Theme.of(context).colorScheme.primary),
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
                raw == _currentFolderRaw ? Icons.folder : Icons.folder_outlined,
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
                            setState(() => _showUrlImportQueue = !_showUrlImportQueue);
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
                                    entry.status != _UrlImportQueueStatus.running &&
                                    entry.status != _UrlImportQueueStatus.queued,
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
                          final linearValue = total > 0 ? progress?.fraction : null;

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
                                  Text(total == 0 ? '準備中...' : '$completed / $total'),
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
      children: [
        body,
        _buildUrlImportQueueOverlay(),
      ],
    );
  }

  List<MediaItem> _gallerySelectionView(int tabIndex) {
    switch (tabIndex) {
      case 1:
        return _applyUntagged(_items);
      case 2:
        return _favoriteItemsAll;
      default:
        return _applyFilter(_items, pdfOnly: null);
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
          message:
              'サイドバーまたはホーム画面から表示するフォルダを選択してください。',
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

    return TabBarView(
      children: [
        _buildGrid(
          _applyFilter(_items, pdfOnly: null),
          onRefresh: _handlePullToRefresh,
        ),
        _currentPageMetadataAvailable
            ? _buildGrid(
                _applyUntagged(_items),
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
                _favoriteItemsAll,
                showFolderLabel: true,
                onRefresh: _handlePullToRefresh,
              )
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_page == _MainPage.home) {
      return Scaffold(
        drawer: _isWideLayout(context) ? null : _buildSidebar(),
        appBar: AppBar(
          title: const Text('ホーム'),
          actions: _appendTopBarRescanAction([_buildHomeOverflowMenu()]),
        ),
        body: _wrapBodyWithUrlImportQueue(
          _withSidebar(context, _buildGuardedBody('home-body', _buildHomeBody)),
        ),
      );
    }

    if (_page == _MainPage.search) {
      return Scaffold(
        drawer: _isWideLayout(context) ? null : _buildSidebar(),
        appBar: AppBar(
          title: const Text('検索結果'),
          actions: _buildSearchAppBarActions(),
        ),
        body: _wrapBodyWithUrlImportQueue(
          _withSidebar(
            context,
            _buildGuardedBody('search-body', _buildHomeSearchGalleryBody),
          ),
        ),
      );
    }

    return DefaultTabController(
      length: 3,
      child: Builder(
        builder: (context) {
          final tabController = DefaultTabController.of(context);
          if (!_tabListenerInstalled) {
            _tabListenerInstalled = true;
            tabController.addListener(() {
              if (!tabController.indexIsChanging && tabController.index == 2) {
                _refreshAllFavoritesItems();
              }
            });
          }

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
                _folder == null ? '一覧表示' : '一覧表示: ${_folderLabel(_folder!.raw)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              actions: _buildGalleryAppBarActions(tabController),
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(160),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      child: SizedBox(
                        height: 44,
                        child: TextField(
                          controller: _searchCtrl,
                          decoration: InputDecoration(
                            prefixIcon: const Icon(Icons.search),
                            hintText: 'タイトル / #タグ / artist:xxx / series:yyy',
                            border: const OutlineInputBorder(),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(vertical: 10),
                            suffixIcon: _query.trim().isEmpty
                                ? null
                                : IconButton(
                                    tooltip: 'クリア',
                                    icon: const Icon(Icons.clear),
                                    onPressed: () {
                                      _searchCtrl.clear();
                                      setState(() => _query = '');
                                    },
                                  ),
                          ),
                          onChanged: (value) => setState(() => _query = value),
                        ),
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
                                child: CircularProgressIndicator(strokeWidth: 2),
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
    );
  }
  String? _normalizeTagName(String raw) {
    var t = raw.trim();
    if (t.isEmpty) return null;
    if (t.startsWith('#')) t = t.substring(1).trim();
    if (t.isEmpty) return null;
    if (t.contains(RegExp(r'\s'))) return null;
    return t;
  }

  String _categoryLabel(TagCategory c) {
    switch (c) {
      case TagCategory.artist:
        return '作家';
      case TagCategory.series:
        return 'シリーズ';
      case TagCategory.mediaType:
        return '種別';
      case TagCategory.character:
        return 'キャラ';
      case TagCategory.free:
        return '自由';
    }
  }

  Future<void> _bulkAddTagToItems(List<MediaItem> targets) async {
    if (targets.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('対象がありません')));
      return;
    }

    TagCategory cat = TagCategory.free;
    final ctrl = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text('一括タグ付与（${targets.length}件）'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<TagCategory>(
                value: cat,
                items: TagCategory.values
                    .map(
                      (c) => DropdownMenuItem(
                        value: c,
                        child: Text(_categoryLabel(c)),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (v) => cat = v ?? TagCategory.free,
                decoration: const InputDecoration(
                  labelText: 'カテゴリ',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'タグ名',
                  hintText: '例: #漫画 / artist:xxx / series:xxx',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => Navigator.of(ctx).pop(true),
              ),
              const SizedBox(height: 8),
              const Text(
                '空白を含むタグは不可です（検索の分解が崩れるため）',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('キャンセル'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('付与'),
            ),
          ],
        );
      },
    );

    if (ok != true) return;

    final name = _normalizeTagName(ctrl.text);
    if (name == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('タグが無効です（空白なしで入力してください）')));
      return;
    }

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      await widget.tagService.addTagToItems(
        targets,
        Tag(name: name, category: cat),
      );

      final got = await widget.tagService.getTagNamesByItems(targets);
      if (!mounted) return;
      setState(() {
        for (final e in got.entries) {
          for (final vv in _idVariants(e.key)) {
            _dbTagsByItemId[vv] = e.value;
          }
        }
      });
      await _refreshCurrentPageTags();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('「$name」を${targets.length}件に付与しました')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('一括タグ付けに失敗しました: $e')));
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
  }

  Future<void> _importSelectedToLibrary(List<MediaItem> targets) async {
    if (targets.isEmpty) return;
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
      targets,
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
          if (_galleryTotal > _pageSize)
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

    return InkWell(
      onLongPress: () {
        if (item.kind == MediaKind.folder) return;
        if (!_selectMode) {
          _enterSelectMode(item);
        } else {
          _toggleSelect(item);
        }
      },
      onTap: () async {
        if (item.kind == MediaKind.folder) {
          if (_selectMode) return;
          _exitSelectMode();
          await _enterFolder(item);
          return;
        }

        if (_selectMode) {
          _toggleSelect(item);
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
        }
      },
      child: _ThumbTile(
        repo: widget.repo,
        item: item,
        subtitle: showFolderLabel ? _folderLabelForItem(item) : null,
        isFavorite: isFavorite,
        onToggleFavorite: () => _toggleFavorite(item),
        selected: isSelected,
        folderTileMode: _folderTileMode,
        canDeletePdf: !_selectMode && _canDeletePdfItem(item),
        onDeletePdf: () => _deletePdfFromList(item),
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

  Widget _buildGridFromList(
    List<MediaItem> items, {
    bool showFolderLabel = false,
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
      child: GridView.builder(
        physics: _refreshScrollPhysics,
        cacheExtent: 200,
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 220,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.75,
        ),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          return _buildGridTile(
            item,
            showFolderLabel: showFolderLabel,
            detailItemsSource: items,
          );
        },
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
  final bool canDeletePdf;
  final VoidCallback? onDeletePdf;

  const _ThumbTile({
    required this.repo,
    required this.item,
    this.subtitle,
    required this.isFavorite,
    required this.onToggleFavorite,
    this.selected = false,
    required this.folderTileMode,
    this.canDeletePdf = false,
    this.onDeletePdf,
  });

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
          const Positioned(top: 8, right: 8, child: _FolderBadge()),
          Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: _TitleChip(title: item.displayName, subtitle: subtitle),
          ),
          if (selected) _buildSelectionOverlay(),
        ],
      ),
    );
  }

  Widget _buildFolderPreviewTile(BuildContext context) {
    final galleryState = context.findAncestorStateOfType<_GalleryGridPageState>();
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
          const Positioned(top: 8, right: 8, child: _FolderBadge()),
          Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: _TitleChip(title: item.displayName, subtitle: subtitle),
          ),
          if (selected) _buildSelectionOverlay(),
        ],
      ),
    );
  }

  Widget _buildMediaTile(BuildContext context) {
    final galleryState = context.findAncestorStateOfType<_GalleryGridPageState>();
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
                _FavButton(
                  isFavorite: isFavorite,
                  onPressed: onToggleFavorite,
                ),
                if (canDeletePdf && onDeletePdf != null) ...[
                  const SizedBox(width: 4),
                  PopupMenuButton<_ThumbTileMenuAction>(
                    tooltip: 'PDF メニュー',
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.more_vert, size: 18),
                    onSelected: (action) {
                      if (action == _ThumbTileMenuAction.deletePdf) {
                        onDeletePdf!.call();
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: _ThumbTileMenuAction.deletePdf,
                        child: ListTile(
                          leading: Icon(Icons.delete_outline),
                          title: Text('PDF を削除'),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: _TitleChip(title: item.displayName, subtitle: subtitle),
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

  Widget _buildSelectionOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withOpacity(0.35),
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
      color: Colors.black.withOpacity(0.55),
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
        color: Colors.black.withOpacity(0.65),
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
        color: Colors.black.withOpacity(0.65),
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
        color: Colors.black.withOpacity(0.65),
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



