import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, Platform;
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
import 'tag_assign_after_import.dart';

import '../repository/mediaRepository.dart';

import 'artistTagIndex.dart';
import 'detailImage.dart';
import 'metadata_settings_dialog.dart';

enum _SortMode { name, updatedAt, addedAt }

enum _MainPage { home, gallery, search }

enum _HomeMenuAction {
  addFolder,
  importToLibrary,
  artistTagIndex,
  metadataSettings,
  refreshFavorites,
  openSearchGallery,
}

enum _GalleryMenuAction {
  addFolder,
  addFile,
  exportPdf,
  organizeLibrary,
  folderTileMode,
  metadataSettings,
  goHome,
}

enum FolderTileMode {
  labelOnly,      // 繝輔か繝ｫ繝繧｢繧､繧ｳ繝ｳ・句錐蜑阪□縺托ｼ域怙霆ｽ驥擾ｼ・
  preview,        // 繝輔か繝ｫ繝蜀・・陦ｨ邏吶・繝ｬ繝薙Η繝ｼ・祈OLDER繝舌ャ繧ｸ・磯㍾繧・ｼ・
}

class _PrefsKeys {
  // 譌ｧ繧ｭ繝ｼ
  static const String lastFolderRaw = 'prefs.lastFolderRaw';

  // 隍・焚繝輔か繝ｫ繝邂｡逅・畑
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

  int _loadProcessed = 0;
  int _loadTotal = 0;
  bool _thumbsEnabled = true;

  // --- 繧ｹ繧ｯ繝ｭ繝ｼ繝ｫ荳ｭ縺ｯ繧ｵ繝繝咲函謌舌ｒ豁｢繧√ｋ ---
  Timer? _thumbResumeDebounce;

  // --- 繝輔か繝ｫ繝陦ｨ邏吶・繝ｬ繝薙Η繝ｼ・哭RU繧ｭ繝｣繝・す繝･ + 蜷梧凾螳溯｡梧焚蛻ｶ髯・---
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
    // null 繧ゅ御ｸｭ霄ｫ縺ｪ縺励阪く繝｣繝・す繝･縺ｨ縺励※謇ｱ縺・ｼ亥酔縺俶爾邏｢繧堤ｹｰ繧願ｿ斐＆縺ｪ縺・ｼ・
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
    // Windows縺ｧ縺ｮ"C:\a\b\c.jpg" / "C:/a/b/c.jpg" 縺ｩ縺｡繧峨ｂ蟇ｾ蠢・
    final p = fullPath.replaceAll('/', '\\');
    final idx = p.lastIndexOf('\\');
    if (idx <= 0) return p; // 蠢ｵ縺ｮ縺溘ａ縺ｭ
    return p.substring(0, idx);
  }

  Set<String> _favorites = <String>{};

  // tags（タグID付き）
  Map<String, List<String>> _tagsById = <String, List<String>>{};
  Map<String, List<TagWithId>> _tagDetailsById = <String, List<TagWithId>>{};
  bool _currentPageMetadataAvailable = true;

  _MainPage _page = _MainPage.home; // 襍ｷ蜍墓凾縺ｯ繝帙・繝・医％縺薙〒縺ｩ縺薙ｒ襍ｷ蜍輔☆繧九°謖・ｮ壹＠縺ｦ縺・ｋ縲ゑｼ・

  // 隍・焚繝輔か繝ｫ繝
  List<String> _foldersRaw = const []; // 逋ｻ骭ｲ貂医∩繝輔か繝ｫ繝荳隕ｧ・・aw・・
  String? _currentFolderRaw; // 迴ｾ蝨ｨ驕ｸ謚橸ｼ・aw・・

  // 陦ｨ遉ｺ險ｭ螳夲ｼ域ｰｸ邯壼喧・・
  ReaderFitMode _fitMode = ReaderFitMode.vertical;
  bool _twoPage = false;

  // 繝帙・繝逕ｻ髱｢讀懃ｴ｢ (縺吶∋縺ｦ縺ｮ繝輔か繝ｫ繝繧貞盾辣ｧ)
  final TextEditingController _homeSearchCtrl = TextEditingController();
  String _homeQuery = '';
  bool _homeSearching = false;
  List<MediaItem> _homeSearchResults = const [];

  // 讀懃ｴ｢谺・・蜉帙・縺溘・縺ｫ蜈ｨ繝輔か繝ｫ繝讀懃ｴ｢縺悟虚縺上・繧帝亟縺・
  Timer? _homeSearchDebounce;

  // Home讀懃ｴ｢逕ｨ縲．B縺九ｉ蠑輔＞縺溘ち繧ｰ繧ｭ繝｣繝・す繝･・・temId -> tagNames・・
  Map<String, List<String>> _dbTagsByItemId = <String, List<String>>{};

  // 繝輔か繝ｫ繝髫主ｱ､繝翫ン・医ぐ繝｣繝ｩ繝ｪ繝ｼ蜀・ｼ・
  final List<_FolderNavState> _dirStack = <_FolderNavState>[];

  bool get _canGoUp => _dirStack.isNotEmpty;
  

  Future<void> _enterFolder(MediaItem folderItem) async { 
    if (_folder == null) return;  

    // 縺・∪隕九※縺・ｋ繝輔か繝ｫ繝 + 縺昴・譎ゅ・繝壹・繧ｸ繧堤ｩ阪・遨阪・
    _dirStack.add(_FolderNavState(_folder!, _galleryPageIndex));

    // 蜈･縺｣縺溷・縺ｯ蠕捺擂騾壹ｊ繝壹・繧ｸ1縺九ｉ
    await _loadFolder(FolderHandle(folderItem.id), saveAsLast: false, pageIndex: 0);
  }

  Future<void> _goUpFolder() async {
    if (_dirStack.isEmpty) return;
    final prev = _dirStack.removeLast();

    // 謌ｻ繧区凾縺ｯ縲悟・縺ｮ繝輔か繝ｫ繝縲阪°縺､縲悟・縺ｮ繝壹・繧ｸ縲阪↓蠕ｩ蟶ｰ
    await _loadFolder(prev.folder, saveAsLast: false, pageIndex: prev.pageIndex);
  }

  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  _SortMode _sortMode = _SortMode.name;

  // raw -> 陦ｨ遉ｺ蜷・
  Map<String, String> _folderAliases = <String, String>{};

  // 蜈ｨ繝輔か繝ｫ繝繧堤屮隕悶√♀豌励↓蜈･繧願｡ｨ遉ｺ逕ｨ
  final Map<String, List<MediaItem>> _folderItemsCache = {};
  List<MediaItem> _favoriteItemsAll = const [];
  bool _loadingFavAll = false;

  // Home讀懃ｴ｢逕ｨ・亥・蟶ｰ・九ヵ繧｡繧､繝ｫ縺ｮ縺ｿ・・
  final Map<String, List<MediaItem>> _folderItemsCacheRecursive = {};

  // ---- 隍・焚驕ｸ謚槭Δ繝ｼ繝・----
  bool _selectMode = false;
  final Set<String> _selectedIds = <String>{};

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

  // TabController縺ｮlistener繧剃ｺ碁㍾逋ｻ骭ｲ縺励↑縺・◆繧・
  bool _tabListenerInstalled = false;

  //ID 螟臥ｨｮ逕滓・
  Set<String> _idVariants(String id) {
    final s = <String>{id};

    // Windows逕ｨ
    s.add(id.replaceAll('/', '\\'));
    s.add(id.replaceAll('\\', '/'));

    // Windows逕ｨ縺ｫ縺ｩ縺｣縺｡縺ｧ繧よ鏡縺医ｋ
    final lower = id.toLowerCase();
    s.add(lower);
    s.add(lower.replaceAll('/', '\\'));
    s.add(lower.replaceAll('\\', '/'));

    return s;
  }

  // ---- 繧ｵ繧､繝峨ヰ繝ｼ・壻ｽ懆・ち繧ｰ荳隕ｧ ----
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

    // 繧ｿ繧ｰ讀懃ｴ｢縺ｨ縺励※讀懃ｴ｢邨先棡繝壹・繧ｸ縺ｸ・域里蟄倥・讀懃ｴ｢繧ｰ繝ｪ繝・ラ繧貞・蛻ｩ逕ｨ・・
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

  Future<void> _loadPrefsAndAutoOpenFolder() async {
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
      } catch (error) {
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
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('ホストに接続できません: $error')));
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
        if (current == null) {
          _items = const [];
          _folder = null;
        }
      });
      if (current == null) return;
      await _loadFolder(FolderHandle(current), saveAsLast: false);
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
    });
    if (current == null) return;
    await _loadFolder(FolderHandle(current), saveAsLast: false);
  }
  Future<void> _saveFolderTileMode(FolderTileMode m) async {
  setState(() => _folderTileMode = m);
  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt(_PrefsKeys.folderTileMode, m.index);
  }

  Future<Uint8List?> _getFolderPreviewBytes(MediaItem folderItem) {
    // 繧ｹ繧ｯ繝ｭ繝ｼ繝ｫ荳ｭ / 蛻晄悄謠冗判荳ｭ縺ｯ逕滓・縺励↑縺・
    //if (!_thumbsEnabled) return Future.value(null);

    final key = folderItem.id;

    // bytes繧貞━蜈・
    if (_folderPreviewCache.containsKey(key)) {
      return Future.value(_folderPreviewCacheGet(key));
    }

    final inflight = _folderPreviewInFlight[key];
    if (inflight != null) return inflight;

    Future<MediaItem?> pickCandidateInFolder(String folderRaw) async {
      const int pageLimit = 60;
      const int maxPages = 4; // 譛螟ｧ240莉ｶ縺縺題ｦ九ｋ・磯㍾縺上＠縺ｪ縺・ｼ・

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

        // 譛ｫ蟆ｾ縺ｾ縺ｧ譚･縺・
        if (res.items.length < pageLimit) break;
      }

      return firstImage;
    }

    final fut = () async {
      await _acquireFolderPreviewSlot(1); // 繝輔か繝ｫ繝陦ｨ邏吶・蜷梧凾1縺ｫ謚代∴繧・
      try {
        // 1) 縺ｾ縺夂峩荳九°繧牙呵｣懊ｒ謗｢縺呻ｼ・B繧､繝ｳ繝・ャ繧ｯ繧ｹ邨檎罰縺ｧ騾溘＞・・
        final cand = await pickCandidateInFolder(folderItem.id);
        if (cand != null) {
          final pair = await widget.repo.readThumbPair(cand, maxWidth: 240);
          _folderPreviewCachePut(key, pair.front);
          return pair.front;
        }

        // 2) 逶ｴ荳九↓辟｡縺・ｴ蜷茨ｼ壹し繝悶ヵ繧ｩ繝ｫ繝繧貞ｰ代＠縺縺題ｦ九ｋ・・谿ｵ縺縺代∵怙螟ｧ3蛟具ｼ・
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

    // 遨ｺ逋ｽ繧貞玄蛻・▲縺ｦ縲、ND繧定ｿｽ蜉
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

      // #tag 縺ｯ繧ｿ繧ｰ縺ｮ縺ｿ蟇ｾ雎｡
      if (t.startsWith('#')) {
        final needle = t.substring(1);
        if (needle.isEmpty) return true;
        return tags.any((x) => x.contains(needle));
      }

      // 騾壼ｸｸ縺ｯ 繝輔ぃ繧､繝ｫ蜷・or 繧ｿ繧ｰ
      return name.contains(t) || tags.any((x) => x.contains(t));
    }

    for (final t in tokens) {
      if (!matchToken(t)) return false;
    }
    return true;
  }

  Future<void> _runHomeSearch() async {
    final q = _homeQuery.trim();
    if (q.isEmpty) {
      if (!mounted) return;
      setState(() {
        _homeSearching = false;
        _homeSearchResults = const [];
      });
      return;
    }

    if (!mounted) return;
    setState(() => _homeSearching = true);

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
      });
    } catch (e, st) {
      // 縺ｪ繧薙〒讀懃ｴ｢縺ｧ縺阪↑縺・・縺九ｏ縺九ｉ縺ｪ縺・
      // 縺薙％縺瑚ｦ九∴縺ｪ縺・→蜴溷屏縺梧ｰｸ驕縺ｫ蛻・°繧峨↑縺・・縺ｧ繝ｭ繧ｰ縺ｫ蜃ｺ縺・
      print('[HOME SEARCH] error: $e\n$st');

      if (!mounted) return;
      setState(() {
        _homeSearching = false;
        _homeSearchResults = const [];
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

      // 陦ｨ遉ｺ譖ｴ譁ｰ・壻ｻ願ｦ九※繧九ヵ繧ｩ繝ｫ繝縺御ｿ晉ｮ｡蠎ｫ驟堺ｸ九↑繧峨Μ繝ｭ繝ｼ繝・
      if (_currentFolderRaw != null && _currentFolderRaw!.startsWith(lib.raw)) {
        await _loadFolder(FolderHandle(_currentFolderRaw!), saveAsLast: false);
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('菫晉ｮ｡蠎ｫ謨ｴ逅・ 遘ｻ蜍・${moved.length} 莉ｶ')));
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
    final folderCount = _foldersRaw.length;
    final currentLabel = _currentFolderRaw == null
        ? '未選択'
        : _folderLabel(_currentFolderRaw!);

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // Home縺ｮ讀懃ｴ｢
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
                      // Home讀懃ｴ｢縺ｯ _homeQuery 繧呈峩譁ｰ縺励※ Home讀懃ｴ｢繧定ｵｰ繧峨○繧・
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
                      icon: const Icon(Icons.create_new_folder_outlined),
                      label: const Text('フォルダ追加'),
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
                              // 繧ｵ繝繝搾ｼ磯ｫ倥＆繧貞・繧後ｋ・・
                              SizedBox(
                                height: 120, // 竊・縺薙％繧貞､峨∴繧九→螟ｧ縺阪＆縺悟､峨ｏ繧・
                                child: _homeFavThumb(item),
                              ),

                              const SizedBox(width: 12),

                              // 繝・く繧ｹ繝磯伜沺
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
                  const Text('登録フォルダがありません。「フォルダを追加」から追加してください。')
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
    );
  }

  Widget _buildHomeSearchGalleryBody() {
    if (_homeSearching) {
      return const Center(child: CircularProgressIndicator());
    }

    final q = _homeQuery.trim();
    if (q.isEmpty) {
      return const Center(
        child: Text('Home の検索欄にキーワード、タグ、#tag を入力してください。'),
      );
    }

    if (_homeSearchResults.isEmpty) {
      return const Center(child: Text('該当するアイテムがありません'));
    }

    // Home讀懃ｴ｢邨先棡縺ｯ蜈ｨ繝輔か繝ｫ繝縺縺九ｉ縲＼items・育樟蝨ｨ繝輔か繝ｫ繝・峨ｒ菴ｿ繧上★
    // 讀懃ｴ｢邨先棡繝ｪ繧ｹ繝医ｒ縺昴・縺ｾ縺ｾ貂｡縺励※隧ｳ邏ｰ繝壹・繧ｸ縺ｧ蜑榊ｾ檎ｧｻ蜍輔〒縺阪ｋ繧医≧縺ｫ縺吶ｋ
    return _buildGridFromList(_homeSearchResults, showFolderLabel: true);
  }

  // --------------------
  // 繝輔か繝ｫ繝陦ｨ遉ｺ蜷崎ｨｭ螳・
  // --------------------
  String _basename(String raw) {
    String s = raw;
    //縲繧｢繝ｳ繝峨Ο繧､繝牙ｯｾ蠢懊′繧・ｄ縺薙＠縺・・縺ｧ・托ｼ搾ｼ斐・鬆・分騾壹ｊ縺ｫ繧・ｋ縲・
    // 1) SAF縺ｮ content://... 縺ｮ蝣ｴ蜷医・ tree/document 縺ｮ谺｡縺ｮsegs・医そ繧ｰ繝｡繝ｳ繝茨ｼ峨ｒ蜿悶ｊ蜃ｺ縺・
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
          s = encoded; // 萓・ primary%3ADocuments%2Fexperiment・・ndroid縺ｮ蝣ｴ蜷医∝ｮ滄ｨ薙ヵ繧ｩ繝ｫ繝繧剃ｽｿ縺・ｼ・
        }
      } catch (_) {
        // 螟ｱ謨励＠縺溘ｉ s=raw 縺ｮ縺ｾ縺ｾ繝輔か繝ｼ繝ｫ繝舌ャ繧ｯ
      }
    }

    // 2) 縲継rimary%3A...縲阪∩縺溘＞縺ｫ繧ｨ繝ｳ繧ｳ繝ｼ繝画枚蟄怜・縺縺台ｿ晏ｭ倥＆繧後※縺・ｋ繧ｱ繝ｼ繧ｹ縺ｫ繧ょｯｾ蠢・
    //    莠碁㍾繧ゅ≠繧雁ｾ励ｋ縺ｮ縺ｧ譛螟ｧ2蝗槫屓縺吶・
    for (int i = 0; i < 2; i++) {
      if (!s.contains('%')) break;
      try {
        s = Uri.decodeComponent(s);
      } catch (_) {
        break;
      }
    }

    // 3) "primary:" 縺ｪ縺ｩ繝懊Μ繝･繝ｼ繝蜷阪ｒ關ｽ縺ｨ縺・竊・譛蠕後・繝代せ隕∫ｴ縺縺代↓縺吶ｋ
    final colon = s.indexOf(':');
    if (colon >= 0) s = s.substring(colon + 1);

    s = s.replaceAll('\\', '/');
    final slash = s.lastIndexOf('/');
    if (slash >= 0) s = s.substring(slash + 1);

    // 4) 遨ｺ縺ｪ繧牙・縺ｮ raw 繧定ｿ斐☆
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
    const patterns = <String>[
      '繝',
      '繧',
      '縺',
      '荳',
      '譛',
      '逋ｻ',
      '讀懃ｴ｢',
      '驕',
      '蜑',
      '隧',
      '邏',
      '陦',
      '遉',
      '莉ｶ',
      '蠖',
      '閾',
      '髢',
      '繝帙',
      '･',
      '｢',
      '｣',
    ];
    return patterns.any(value.contains);
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
  // 豌ｸ邯壼喧・夊｡ｨ遉ｺ險ｭ螳・
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
  // 縺頑ｰ励↓蜈･繧奇ｼ遺・・・
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

    // 繝輔か繝ｫ繝縺梧悴逋ｻ骭ｲ縺ｪ繧臥匳骭ｲ
    if (!_foldersRaw.contains(folderRaw)) {
      final next = List<String>.from(_foldersRaw)..add(folderRaw);
      setState(() {
        _foldersRaw = next;
        _currentFolderRaw = folderRaw;
      });

      await _persistFolders();
    } else {
      // 逋ｻ骭ｲ貂医∩縺ｪ繧・current 繧偵ヵ繧ｩ繝ｫ繝繝ｼ縺ｫ蜷医ｏ縺帙ｋ
      if (_currentFolderRaw != folderRaw) {
        setState(() {
          _currentFolderRaw = folderRaw;
          _folder = FolderHandle(folderRaw);
        });
        await _persistFolders();
      }
    }

    // 蟇ｾ雎｡繝輔か繝ｫ繝繧偵Ο繝ｼ繝会ｼ医く繝｣繝・す繝･縺後≠繧後・縺昴ｌ繧剃ｽｿ縺・ｼ・
    if (_folderItemsCache.containsKey(folderRaw)) {
      setState(() {
        _items = _folderItemsCache[folderRaw] ?? const [];
        _folder = FolderHandle(folderRaw);
      });
    } else {
      await _loadFolder(FolderHandle(folderRaw), saveAsLast: false);
      // _loadFolder 縺・_items 繧呈峩譁ｰ縺吶ｋ縺ｨ縺阪↓繧ｭ繝｣繝・す繝･縺ｫ繧ょ・繧後※縺翫￥
      _folderItemsCache[folderRaw] = _items;
    }

    // 蟄伜惠縺励※縺・ｋindex 繧呈爾縺呻ｼ医↑縺・ｴ蜷医・Snackbar縺ｧ繝・く繧ｹ繝医ｒ霑斐☆・・
    final idx = _items.indexWhere((e) => e.id == item.id);
    if (idx < 0) {
      if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ファイルが見つかりません。移動または削除された可能性があります。')),
        );
      return;
    }

    // 隧ｳ邏ｰ繝壹・繧ｸ縺ｸ荳逋ｺ縺ｧ驕ｷ遘ｻ縺吶ｋ縲・
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

    // detail繝壹・繧ｸ縺ｧ縺頑ｰ励↓蜈･繧翫′螟峨ｏ縺｣縺溷ｴ蜷医√・繝ｼ繝縺ｮ荳隕ｧ縺ｮ縺頑ｰ励↓蜈･繧翫ｂ譖ｴ譁ｰ
    if (changed == true) {
      await _reloadFavorites();
      await _refreshAllFavoritesItems();
      if (_homeQuery.trim().isNotEmpty) {
        await _runHomeSearch(); // 繧ｿ繧ｰ螟画峩繧辿ome讀懃ｴ｢縺ｫ蜿肴丐
      }
    }
  }

  /// 縺頑ｰ励↓蜈･繧贋ｸ隕ｧ縺ｪ縺ｩ縺ｧ縲後％縺ｮ繧｢繧､繝・Β縺悟ｱ槭☆繧九ヵ繧ｩ繝ｫ繝縺ｮ陦ｨ遉ｺ蜷阪阪ｒ霑斐☆
  String _folderLabelForItem(MediaItem item) {
    // 縺頑ｰ励↓蜈･繧翫・縲悟・繝輔か繝ｫ繝讓ｪ譁ｭ縲阪↑縺ｮ縺ｧ縲・
    // 逋ｻ骭ｲ貂医∩繝輔か繝ｫ繝・・foldersRaw・峨・縺ｩ繧後↓螻槭☆繧九°繧呈耳螳壹＠縺ｦ陦ｨ遉ｺ縺吶ｋ縲・
    final itemNorm = _normalizePath(item.id);

    String? bestMatchRaw;
    var bestLen = -1;

    for (final raw in _foldersRaw) {
      final folderNorm = _normalizePath(raw);

      // "C:\pics" 縺ｨ "C:\pics2" 縺ｮ隱､荳閾ｴ繧帝∩縺代ｋ縺溘ａ縲∵怙蠕後・蛹ｺ蛻・ｊ縺ｾ縺ｧ隕九ｋ縲・
      final ok = itemNorm == folderNorm || itemNorm.startsWith('$folderNorm\\');
      if (!ok) continue;

      if (folderNorm.length > bestLen) {
        bestLen = folderNorm.length;
        bestMatchRaw = raw;
      }
    }

    if (bestMatchRaw != null) {
      return _folderLabel(bestMatchRaw); // alias 縺後≠繧後・ alias縲∫┌縺代ｌ縺ｰ basename
    }

    // 逋ｻ骭ｲ螟悶・繝輔か繝ｫ繝縺九ｉ譚･縺溷ｴ蜷医・縺吶＄荳翫・繝輔か繝ｫ繝蜷阪ｒ陦ｨ遉ｺ
    final parentRaw = _parentDirOfFullPath(item.id);
    return _basename(parentRaw);
  }

  String _normalizePath(String p) {
    // Windows逕ｨ
    var s = p.replaceAll('/', '\\');
    while (s.endsWith('\\')) {
      s = s.substring(0, s.length - 1);
    }
    return s.toLowerCase();
  }

  // --------------------
  // 繝輔か繝ｫ繝繝ｼ邂｡逅・
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

      setState(() {
        _galleryTotal = res.total; 
        _items = res.items;
        _loading = false;
      });

      widget.tagService.rememberItems(res.items);
      unawaited(_refreshCurrentPageTags(res.items));

      WidgetsBinding.instance.addPostFrameCallback((_) async {
       // 荳隕ｧ繧貞・縺ｫ謠冗判縺輔○縺ｦ縺九ｉ繧ｵ繝繝埼幕蟋・
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (!mounted) return;
        setState(() => _thumbsEnabled = true);
      });

      _folderItemsCache[folder.raw] = _items;
      await _refreshAllFavoritesItems();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('フォルダの読み込みに失敗しました: $e')),
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

      setState(() {
        _galleryPageIndex = pageIndex;
        _items = res.items;
        _loading = false;
      });

      widget.tagService.rememberItems(res.items);
      unawaited(_refreshCurrentPageTags(res.items));

      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (!mounted) return;
        setState(() => _thumbsEnabled = true);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ページの読み込みに失敗しました: $e')),
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
    if (widget.repo.isRemoteMode) {
      List<FolderHandle> remoteFolders = const <FolderHandle>[];
      try {
        remoteFolders = await widget.repo.listAvailableFolders();
      } catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('ホストに接続できません: $error')));
        return;
      }
      if (!mounted) return;
      final raws = remoteFolders.map((entry) => entry.raw).toList(growable: false);
      setState(() {
        _foldersRaw = raws;
        _currentFolderRaw ??= raws.isNotEmpty ? raws.first : null;
      });
      if (_currentFolderRaw != null) {
        await _loadFolder(FolderHandle(_currentFolderRaw!), saveAsLast: false);
      }
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
    final next = List<String>.from(_foldersRaw)..remove(raw);

    String? nextCurrent = _currentFolderRaw;
    if (nextCurrent == raw) {
      nextCurrent = next.isNotEmpty ? next.first : null;
    }

    setState(() {
      _foldersRaw = next.toList(growable: false);
      _currentFolderRaw = nextCurrent;
      _folder = nextCurrent == null ? null : FolderHandle(nextCurrent);
      _items = const [];
    });

    _folderItemsCache.remove(raw);
    await _refreshAllFavoritesItems();

    await _persistFolders();

    if (nextCurrent == null) return;
    await _loadFolder(FolderHandle(nextCurrent), saveAsLast: false);
  }

  Future<void> _importToCurrentFolder() async {
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
    final progress = ValueNotifier<MediaTransferProgress?>(null);
    var dialogShown = false;
    try {
      final lib = await widget.repo.getAppLibraryFolder();
      final libRaw = lib.raw;

      // folders 縺ｫ菫晉ｮ｡蠎ｫ縺後↑縺代ｌ縺ｰ蜈･繧後ｋ・亥ｿｵ縺ｮ縺溘ａ・・
      if (!_foldersRaw.contains(libRaw)) {
        setState(() {
          _foldersRaw = <String>[libRaw, ..._foldersRaw];
        });
        await _persistFolders();
      }

      // 蜿悶ｊ霎ｼ縺ｿ蜑阪・繧ｹ繝翫ャ繝励す繝ｧ繝・ヨ
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

      // 蜿悶ｊ霎ｼ縺ｿ螳溯｡・
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

      // 蜿悶ｊ霎ｼ縺ｿ蠕鯉ｼ壼ｷｮ蛻・歓蜃ｺ
      final after = await widget.repo.listMedia(lib);
      final newItems = after
          .where((e) => e.kind != MediaKind.folder && !beforeIds.contains(e.id))
          .toList(growable: false);

      // 縺ｾ縺壻ｿ晉ｮ｡蠎ｫ繧帝幕縺擾ｼ医ち繧ｰ逕ｻ髱｢縺ｮ蜑阪↓縲御ｿ晉ｮ｡蠎ｫ縺檎樟蝨ｨ繝輔か繝ｫ繝縲阪↓縺ｪ繧九ｈ縺・↓・・
      _dirStack.clear();
      setState(() {
        _currentFolderRaw = libRaw;
        _page = _MainPage.gallery; // 菫晉ｮ｡蠎ｫ縺ｸ蜿悶ｊ霎ｼ繧薙□繧峨ぐ繝｣繝ｩ繝ｪ繝ｼ陦ｨ遉ｺ縺ｫ蟇・○繧・
      });
      await _persistFolders();

      // 繧ｮ繝｣繝ｩ繝ｪ繝ｼ繧剃ｿ晉ｮ｡蠎ｫ縺ｧ譖ｴ譁ｰ陦ｨ遉ｺ
      await _loadFolder(lib, saveAsLast: false);
      if (!mounted) return;

      // 蟾ｮ蛻・′蜿悶ｌ縺ｪ縺・ｴ蜷医〒繧ゅ∝叙繧願ｾｼ縺ｿ謌仙粥縺ｮ騾夂衍縺ｯ蜃ｺ縺・
      if (newItems.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('ライブラリへ取り込み: $importedCount 件（差分なし）')),
        );
        return;
      }

      // 繧ｿ繧ｰ莉倥￠逕ｻ髱｢繧貞・縺・
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TagAssignAfterImportPage(
            items: newItems,
            tagService: widget.tagService,
          ),
        ),
      );

      if (!mounted) return;

      // 繧ｿ繧ｰ莉倥￠蠕鯉ｼ唏ome讀懃ｴ｢繧・ｻｶ謨ｰ陦ｨ遉ｺ縺ｫ繧ょ渚譏縺輔○縺溘＞縺ｮ縺ｧ繧ｭ繝｣繝・す繝･譖ｴ譁ｰ
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

  Future<void> _refreshAllFavoritesItems() async {
    if (_loadingFavAll) return;
    if (_foldersRaw.isEmpty) {
      if (!mounted) return;
      setState(() => _favoriteItemsAll = const []);
      return;
    }

    setState(() => _loadingFavAll = true);

    try {
      // 譛ｪ繧ｭ繝｣繝・す繝･縺ｮ繝輔か繝ｫ繝縺縺題ｪｭ縺ｿ霎ｼ繧
      for (final raw in _foldersRaw) {
        if (_folderItemsCache.containsKey(raw)) continue;
        final items = await widget.repo.listMedia(FolderHandle(raw));
        _folderItemsCache[raw] = items;
      }

      // 蜈ｨ繝輔か繝ｫ繝蛻・°繧峨♀豌励↓蜈･繧翫□縺第歓蜃ｺ
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
        // 笨・folder 縺ｯ蟶ｸ縺ｫ谿九＠縺､縺､縲｝df 繧定｡ｨ遉ｺ
        out = out.where((e) => e.kind == MediaKind.folder || e.kind == MediaKind.pdf);
      } else {
        // 笨・folder 縺ｯ蟶ｸ縺ｫ谿九＠縺､縺､縲（mage 繧定｡ｨ遉ｺ
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

  /// 縲後ち繧ｰ縺ｪ縺励阪ち繝也畑: 繝輔か繝ｫ繝縺ｯ髯､螟悶＠縲√ち繧ｰ縺・縺､繧ゆｻ倥＞縺ｦ縺・↑縺・判蜒・PDF縺ｮ縺ｿ陦ｨ遉ｺ
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
      case _GalleryMenuAction.exportPdf:
        if (widget.repo.isRemoteMode) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('\u30ea\u30e2\u30fc\u30c8\u30e2\u30fc\u30c9\u3067\u306f PDF \u66f8\u304d\u51fa\u3057\u306f\u672a\u5bfe\u5fdc\u3067\u3059')),
          );
          return;
        }
        await _exportCurrentFolderImagesToPdf();
        return;
      case _GalleryMenuAction.organizeLibrary:
        if (widget.repo.isRemoteMode) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('\u30ea\u30e2\u30fc\u30c8\u30e2\u30fc\u30c9\u3067\u306f\u30e9\u30a4\u30d6\u30e9\u30ea\u6574\u7406\u306f\u672a\u5bfe\u5fdc\u3067\u3059')),
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
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: _HomeMenuAction.addFolder,
          child: ListTile(
            leading: Icon(Icons.create_new_folder_outlined),
            title: Text('フォルダ追加'),
          ),
        ),
        PopupMenuItem(
          value: _HomeMenuAction.importToLibrary,
          child: ListTile(
            leading: Icon(Icons.archive_outlined),
            title: Text('ライブラリへ取り込み'),
          ),
        ),
        PopupMenuItem(
          value: _HomeMenuAction.artistTagIndex,
          child: ListTile(
            leading: Icon(Icons.person),
            title: Text('アーティストタグ一覧'),
          ),
        ),
        PopupMenuItem(
          value: _HomeMenuAction.metadataSettings,
          child: ListTile(
            leading: Icon(Icons.settings_outlined),
            title: Text('動作モード設定'),
          ),
        ),
        PopupMenuItem(
          value: _HomeMenuAction.refreshFavorites,
          child: ListTile(
            leading: Icon(Icons.star),
            title: Text('お気に入り更新'),
          ),
        ),
        PopupMenuItem(
          value: _HomeMenuAction.openSearchGallery,
          child: ListTile(
            leading: Icon(Icons.grid_view),
            title: Text('検索結果（ギャラリー表示）'),
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
    itemBuilder: (context) => [
      const PopupMenuItem(
        value: _GalleryMenuAction.folderTileMode,
        child: ListTile(
          leading: Icon(Icons.folder_open_outlined),
          title: Text('フォルダ表示'),
        ),
      ),
        const PopupMenuItem(
          value: _GalleryMenuAction.addFolder,
          child: ListTile(
            leading: Icon(Icons.create_new_folder_outlined),
            title: Text('フォルダ追加'),
          ),
        ),
        PopupMenuItem(
          value: _GalleryMenuAction.addFile,
          enabled: _currentFolderRaw != null,
          child: const ListTile(
            leading: Icon(Icons.upload_file_outlined),
            title: Text('ファイル追加'),
          ),
        ),
        PopupMenuItem(
          value: _GalleryMenuAction.organizeLibrary,
          child: ListTile(
            leading: Icon(Icons.auto_awesome_mosaic_outlined),
            title: Text('ライブラリ整理（作家・シリーズ）'),
          ),
        ),
        const PopupMenuItem(
          value: _GalleryMenuAction.metadataSettings,
          child: ListTile(
            leading: Icon(Icons.settings_outlined),
            title: Text('動作モード設定'),
          ),
        ),
        const PopupMenuItem(
          value: _GalleryMenuAction.exportPdf,
          child: ListTile(
            leading: Icon(Icons.picture_as_pdf_outlined),
            title: Text('このフォルダの画像を PDF にまとめる'),
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

    final images = _applyFilter(_items, pdfOnly: false);
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PDF菫晏ｭ伜ｮ御ｺ・ ${created.name}')),
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
  Future<void> _showFolderTileModeDialog() async {
    final mode = await showDialog<FolderTileMode>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('繝輔か繝ｫ繝陦ｨ遉ｺ'),
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
    _saveFolderTileMode(mode); // 竊舌≠縺ｪ縺溘′謖√▲縺ｦ繧区里蟄倬未謨ｰ繧貞他縺ｶ諠ｳ螳・
  }

  // --- UI: responsive sidebar (Windows/desktop friendly) ---
  static const double _kSidebarWidth = 340;

  bool _isWideLayout(BuildContext context) =>
      MediaQuery.of(context).size.width >= 980;

  void _closeSidebar() {
    // Drawer陦ｨ遉ｺ譎ゅ・縺ｿ髢峨§繧具ｼ医ョ繧ｹ繧ｯ繝医ャ繝励・蟶ｸ險ｭ繧ｵ繧､繝峨ヰ繝ｼ縺ｧ縺ｯ pop 縺励↑縺・ｼ・
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

  Widget _buildSidebarListView() {
    return ListView(
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

                // 繝輔か繝ｫ繝譛ｪ驕ｸ謚槭↑繧峨・繝ｼ繝縺ｧ譯亥・・医∪縺溘・繝輔か繝ｫ繝霑ｽ蜉・・
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
                      padding: EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      child: Text('作家タグがまだありません'),
                    )
                  else
                    ..._artistTagMasters.map((tw) {
                      final name = tw.tag.name;
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
                    onChanged: (v) async {
                      if (v == null) return;
                      setState(() => _fitMode = v);
                      await _saveFitMode(v);
                    },
                  ),
                ),
              ),
            ),
            SwitchListTile(
              title: const Text('見開き表示 (ON/OFF)'),
              value: _twoPage,
              onChanged: (v) async {
                setState(() => _twoPage = v);
                await _saveTwoPage(v);
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

            // 霑ｽ蜉繝懊ち繝ｳ
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('フォルダを追加'),
              onTap: () async {
                _closeSidebar();
                await _addFolder();
              },
            ),

            if (_foldersRaw.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text('登録フォルダがありません。上の「フォルダを追加」から追加してください。'),
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
    );
  }

  Drawer _buildSidebar() => Drawer(
        child: SafeArea(child: _buildSidebarListView()),
      );

  Widget _buildSidebarPanel() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: SafeArea(child: _buildSidebarListView()),
    );
  }



  @override
  Widget build(BuildContext context) {
    // 繝帙・繝逕ｻ髱｢
    if (_page == _MainPage.home) {
      return Scaffold(
        drawer: _isWideLayout(context) ? null : _buildSidebar(),
        appBar: AppBar(
          title: const Text('ホーム'),
          actions: [_buildHomeOverflowMenu()],
        ),
        body: _withSidebar(context, _buildHomeBody()),
      );
    }

    // 讀懃ｴ｢邨先棡・・ome讀懃ｴ｢繧偵ぐ繝｣繝ｩ繝ｪ繝ｼ陦ｨ遉ｺ縺吶ｋ縲ゑｼ・
    if (_page == _MainPage.search) {
      return Scaffold(
        drawer: _isWideLayout(context) ? null : _buildSidebar(),
        appBar: AppBar(
          title: const Text('検索結果'),
          actions: _selectMode
              ? [
                  IconButton(
                    tooltip: '驕ｸ謚櫁ｧ｣髯､',
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
                    // 縺薙％縺ｧ縺昴・蝣ｴ縺ｧ繧ｿ繝也分蜿ｷ繧貞叙繧・
                    final tabIndex = DefaultTabController.of(context).index;

                    final List<MediaItem> view;
                    if (tabIndex == 0) {
                      view = _applyFilter(_items, pdfOnly: null);
                    } else if (tabIndex == 1) {
                      view = _applyFilter(_items, pdfOnly: false);
                    } else {
                      view = _applyFilter(_items, pdfOnly: true);
                    }

                    final targets = _selectedFrom(view);
                    _importSelectedToLibrary(targets);
                  },
                    icon: const Icon(Icons.archive_outlined),
                  ),
                ]
              : [
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
                ],
        ),
        body: _withSidebar(context, _buildHomeSearchGalleryBody()),
      );
    }

    // 繧ｮ繝｣繝ｩ繝ｪ繝ｼ逕ｻ髱｢
    return DefaultTabController(
      length: 3,
      child: Builder(
        builder: (context) {
          final TabController tc = DefaultTabController.of(context);
          if (!_tabListenerInstalled) {
            _tabListenerInstalled = true;
            tc.addListener(() {
              if (!tc.indexIsChanging && tc.index == 2) {
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
              actions: _selectMode
                  ? [
                      IconButton(
                        tooltip: '選択解除',
                        onPressed: _exitSelectMode,
                        icon: const Icon(Icons.close),
                      ),
                      IconButton(
                        tooltip: '全選択（現在タブ）',
                        onPressed: () {
                          final idx = tc.index;
                          final List<MediaItem> view;
                          if (idx == 0) {
                            view = _applyFilter(_items, pdfOnly: null);
                          } else if (idx == 1) {
                            view = _applyUntagged(_items);
                          } else {
                            view = _favoriteItemsAll;
                          }
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
                          final idx = tc.index;
                          final List<MediaItem> view;
                          if (idx == 0) {
                            view = _applyFilter(_items, pdfOnly: null);
                          } else if (idx == 1) {
                            view = _applyFilter(_items, pdfOnly: false);
                          } else if (idx == 2) {
                            view = _applyFilter(_items, pdfOnly: true);
                          } else {
                            view = _favoriteItemsAll;
                          }
                          final targets = _selectedFrom(view);
                          _bulkAddTagToItems(targets);
                        },
                        icon: const Icon(Icons.label_outline),
                      ),
                      IconButton(
                        tooltip: '選択中をライブラリに取り込む（重複はスキップ）',
                        onPressed: () {
                          // 縺薙％縺ｧ縺昴・蝣ｴ縺ｧ繧ｿ繝也分蜿ｷ繧貞叙繧・
                            final tabIndex = DefaultTabController.of(context).index;

                          final List<MediaItem> view;
                          if (tabIndex == 0) {
                            view = _applyFilter(_items, pdfOnly: null);
                          } else if (tabIndex == 1) {
                            view = _applyFilter(_items, pdfOnly: false);
                          } else {
                            view = _applyFilter(_items, pdfOnly: true);
                            }

                          final targets = _selectedFrom(view);
                          _importSelectedToLibrary(targets);
                        },
                        icon: const Icon(Icons.archive_outlined),
                      ),
                    ]
                  : [
                      _buildGalleryOverflowMenu(),
                    ],
              bottom: PreferredSize(
                // 讀懃ｴ｢(邏・6) + 繧ｽ繝ｼ繝・邏・0) + TabBar(邏・8) + 菴咏區
                //縲= 160蜑榊ｾ後・蠢・ｦ・
                preferredSize: const Size.fromHeight(160),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ---- 讀懃ｴ｢繝舌・ ----
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      child: SizedBox(
                        height: 44, // 鬮倥＆繧呈ｱｺ螳・
                        child: TextField(
                          controller: _searchCtrl,
                          decoration: InputDecoration(
                            prefixIcon: const Icon(Icons.search),
                            hintText: 'タイトル / #タグ / artist:xxx / series:yyy',
                            border: const OutlineInputBorder(),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 10,
                            ),
                            suffixIcon: (_query.trim().isEmpty)
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
                          onChanged: (v) => setState(() => _query = v),
                        ),
                      ),
                    ),

                    // ---- 繧ｽ繝ｼ繝郁｡・----
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
                              onChanged: (v) {
                                if (v == null) return;
                                setState(() => _sortMode = v);
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

                    // ---- 繧ｿ繝・----
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
            body: _withSidebar(context, _folder == null
                ? Center(
                    child: ElevatedButton(
                      onPressed: _addFolder,
                      child: const Text('フォルダを追加'),
                    ),
                  )
                : _loading
                ? const Center(child: CircularProgressIndicator())
                : _items.isEmpty
                ? const Center(child: Text('画像や PDF がありません'))
                : TabBarView(
                    children: [
                      _buildGrid(_applyFilter(_items, pdfOnly: null)),
                      _buildGrid(_applyUntagged(_items)),
                      _loadingFavAll
                          ? const Center(child: CircularProgressIndicator())
                          : _buildGrid(_favoriteItemsAll, showFolderLabel: true),
                    ],
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
    // 遨ｺ逋ｽ縺ｯ遖∵ｭ｢
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

    // 騾ｲ謐励ム繧､繧｢繝ｭ繧ｰ
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
      // 騾ｲ謐励ム繧､繧｢繝ｭ繧ｰ繧帝哩縺倥ｋ
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
  }

  Future<void> _importSelectedToLibrary(List<MediaItem> targets) async {
    if (targets.isEmpty) return;

    // 蜿悶ｊ霎ｼ縺ｿ蜈茨ｼ井ｿ晉ｮ｡蠎ｫ・・
    final lib = await widget.repo.getAppLibraryFolder();

    // 蜿悶ｊ霎ｼ縺ｿ蜑阪せ繝翫ャ繝励す繝ｧ繝・ヨ・域眠隕丞・繧堤音螳壹＠縺ｦ繧ｿ繧ｰ莉倥￠逕ｻ髱｢縺ｫ繧よｸ｡縺帙ｋ・・
    final before = await widget.repo.listMedia(lib);
    final beforeIds = before.map((e) => e.id).toSet();

    // 蜷悟錐縺後≠繧後・繧ｹ繧ｭ繝・・縺吶ｋ・郁ｻｽ驥城㍾隍・屓驕ｿ・・
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

    // 蜿悶ｊ霎ｼ縺ｿ蠕悟ｷｮ蛻・ｼ昜ｻ雁屓譁ｰ隕上〒蠅励∴縺溘ヵ繧｡繧､繝ｫ
    final after = await widget.repo.listMedia(lib);
    final newItems = after
        .where((e) => e.kind != MediaKind.folder && !beforeIds.contains(e.id))
        .toList(growable: false);

    if (!mounted) return;

    // 蜿悶ｊ霎ｼ縺ｿ逶ｴ蠕後ち繧ｰ莉倥￠・医≠縺ｪ縺溘′蜑阪↓蜈･繧後※縺・ｋ tag_assign_after_import.dart 繧呈ｴｻ逕ｨ・・
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

    // 驕ｸ謚櫁ｧ｣髯､ + 陦ｨ遉ｺ譖ｴ譁ｰ
    _exitSelectMode();
    setState(() {});
  }

  Widget _buildGrid(List<MediaItem> items, {bool showFolderLabel = false}) {
    if (items.isEmpty) {
      return const Center(child: Text('該当するアイテムがありません'));
    }

     return Column(
      children: [
        // 笘・荳逡ｪ荳翫↓繝壹・繧ｸ繝｣
        _buildPager(),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            child: GridView.builder(
              cacheExtent: 200, // 蜈郁ｪｭ縺ｿ謚大宛
              padding: const EdgeInsets.all(12),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.75
            ),
              itemCount: items.length,
              itemBuilder: (context, i) {
                final item = items[i];
                final isFav = _favorites.contains(item.id);
                final selected = _selectedIds.contains(item.id);
  
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

                    final mediaOnly = _items
                        .where((e) => e.kind != MediaKind.folder)
                        .toList(growable: false);
                    final index = mediaOnly.indexWhere((e) => e.id == item.id);

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
                      await _reloadFavorites();
                      await _reloadTags();
                    }
                  },
                  child: _ThumbTile(
                    repo: widget.repo,
                    item: item,
                    isFavorite: isFav,
                    subtitle: showFolderLabel ? _folderLabelForItem(item) : null,
                    onToggleFavorite: () => _toggleFavorite(item),
                    selected: selected,
                    folderTileMode: _folderTileMode,
                  ),
                );
              },
            ),
          ),
        )
      ],
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
                (i) => DropdownMenuItem(
                  value: i,
                  child: Text('ページ ${i + 1}'),
                ),
              ),
              onChanged: (v) {
                if (v == null) return;
                _loadGalleryPage(v);
              },
            )
          else
            Flexible(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: List.generate(totalPages, (i) {
                    final selected = i == clamped;
                    return Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: ChoiceChip(
                        label: Text('${i + 1}'),
                        selected: selected,
                        onSelected: (_) => _loadGalleryPage(i),
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
  }) {
    if (items.isEmpty) {
      return const Center(child: Text('該当するアイテムがありません'));
    }

    return GridView.builder(
      cacheExtent: 200, // 蜈郁ｪｭ縺ｿ謚大宛
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.75,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        final isFav = _favorites.contains(item.id);

        final selected = _selectedIds.contains(item.id);

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

            // folder髯､螟悶〒Detail繝壹・繧ｸ縺ｸ
            final mediaOnly = items
                .where((e) => e.kind != MediaKind.folder)
                .toList(growable: false);
            final index = mediaOnly.indexWhere((e) => e.id == item.id);

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
              await _reloadFavorites();
              await _reloadTags();
            }
          },
          child: _ThumbTile(
            repo: widget.repo,
            item: item,
            isFavorite: isFav,
            subtitle: showFolderLabel ? _folderLabelForItem(item) : null,
            onToggleFavorite: () => _toggleFavorite(item),
            selected: selected,
            folderTileMode: _folderTileMode,
          ),
        );
      },
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

  const _ThumbTile({
    required this.repo,
    required this.item,
    this.subtitle,
    required this.isFavorite,
    required this.onToggleFavorite,
    this.selected = false,
    required this.folderTileMode,
  });

  @override
  Widget build(BuildContext context) {
    // -------------------------
    // 1) Folder tile
    // -------------------------
    if (item.kind == MediaKind.folder) {
    // 竭 霆ｽ驥上Δ繝ｼ繝会ｼ壹・繝ｬ繝薙Η繝ｼ繧剃ｸ蛻・他縺ｰ縺ｪ縺・
    if (folderTileMode == FolderTileMode.labelOnly) {
      return Material(
        elevation: 2,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              Positioned.fill(
                child: Container(
                  alignment: Alignment.center,
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: const Icon(Icons.folder, size: 56),
                ),
              ),
              const Positioned(top: 8, right: 8, child: _FolderBadge()),
              Positioned(
                left: 8,
                right: 8,
                bottom: 8,
                child: _TitleChip(title: item.displayName, subtitle: subtitle),
              ),
              if (selected)
                Positioned.fill(
                  child: Container(
                    color: Colors.black.withOpacity(0.35),
                    alignment: Alignment.topRight,
                    padding: const EdgeInsets.all(8),
                    child: const Icon(Icons.check_circle, size: 26),
                  ),
                ),
            ],
          ),
        );
      }

      // 竭｡ 繝励Ξ繝薙Η繝ｼ繝｢繝ｼ繝会ｼ夊｡ｨ邏吶ｒ蜿門ｾ励＠縺ｦ陦ｨ遉ｺ
      final st = context.findAncestorStateOfType<_GalleryGridPageState>();
      final enabled = st?._thumbsEnabled ?? true;
      
      return Material(
        elevation: 2,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Positioned.fill(
              child: !enabled
                  ? Container(
                      alignment: Alignment.center,
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: const Icon(Icons.folder, size: 56),
                    )
                  : FutureBuilder<Uint8List?>(
                      future: st?._getFolderPreviewBytes(item),
                      builder: (context, snap) {
                        final bytes = snap.data;
                        if (bytes != null && bytes.isNotEmpty) {
                          return Image.memory(
                            bytes,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                            filterQuality: FilterQuality.low,
                          );
                        }
                        return Container(
                          alignment: Alignment.center,
                          color: Theme.of(context).colorScheme.surfaceContainerHighest,
                          child: const Icon(Icons.folder, size: 56),
                        );
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
      
            // 笨・selected overlay・医％縺薙〒 readThumbPair 繧貞他縺ｰ縺ｪ縺・ｼ・
            if (selected)
              Positioned.fill(
                child: Container(
                  color: Colors.black.withOpacity(0.35),
                  alignment: Alignment.topRight,
                  padding: const EdgeInsets.all(8),
                  child: const Icon(Icons.check_circle, size: 26),
                ),
              ),
          ],
        ),
      );
    }

    // -------------------------
    // 2) PDF / Image tile
    // -------------------------

    final st = context.findAncestorStateOfType<_GalleryGridPageState>();
    final enabled = st?._thumbsEnabled ?? true;

    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          // NOTE: _thumbsEnabled 縺・false 縺ｮ髢薙・ FutureBuilder 閾ｪ菴薙ｒ菴懊ｉ縺ｪ縺・ｼ・ 繧ｵ繝繝咲函謌舌ｒ髢句ｧ九＠縺ｪ縺・ｼ・
          Positioned.fill(
            child: (() {
              final st = context.findAncestorStateOfType<_GalleryGridPageState>();
              final enabled = st?._thumbsEnabled ?? true;

              if (!enabled) {
                return _TileShell(loading: true);
              }

              return FutureBuilder<ThumbPair>(
                future: repo.readThumbPair(item, maxWidth: 240),
                builder: (context, snap) {
                  if (!snap.hasData) {
                    return _TileShell(loading: true);
                  }
                  return _ThumbImage(bytes: snap.data!.front);
                },
              );
            })(),
          ),

          // 蜿ｳ荳奇ｼ啀DF繝舌ャ繧ｸ + 笘・
          Positioned(
            top: 8,
            right: 8,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (item.kind == MediaKind.pdf) const _PdfBadge(),
                const SizedBox(width: 6),
                _FavButton(isFavorite: isFavorite, onPressed: onToggleFavorite),
              ],
            ),
          ),

          // 繧ｿ繧､繝医Ν
          Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: _TitleChip(title: item.displayName, subtitle: subtitle),
          ),

          // 驕ｸ謚樊凾
          if (selected)
            Positioned.fill(
              child: Container(
                color: Colors.black.withOpacity(0.35),
                alignment: Alignment.topRight,
                padding: const EdgeInsets.all(8),
                child: const Icon(Icons.check_circle, size: 26),
              ),
            ),
        ],
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
          // 縺薙％縺ｧ螟ｱ謨励ｒ蜃ｺ蜉・
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



