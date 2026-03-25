import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' show Directory, Platform;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../database/tag_service.dart';
import '../models/folder.dart';
import '../models/mediaItem.dart';
import '../models/tag.dart';
import '../database/pdf_export_service.dart';
import '../repository/mediaRepository.dart';
import '../services/external_share_service.dart';
import 'artistTagIndex.dart';
import 'detailImage.dart';
import 'tag_assign_after_import.dart';

enum _SortMode { name, updatedAt, addedAt }

enum _MainPage { home, gallery, search }

enum _HomeMenuAction {
  addFolder,
  importToLibrary,
  artistTagIndex,
  refreshFavorites,
  openSearchGallery,
}

enum _GalleryMenuAction {
  addFolder,
  addFile,
  exportPdf,
  organizeLibrary,
  folderTileMode,
  goHome,
}

enum FolderTileMode {
  labelOnly,      // フォルダアイコン�E�名前だけ（最軽量！E
  preview,        // フォルダ冁E�E表紙�Eレビュー�E�FOLDERバッジ�E�重めE��E
}

class _PrefsKeys {
  // 旧キー
  static const String lastFolderRaw = 'prefs.lastFolderRaw';

  // 褁E��フォルダ管琁E��
  static const String folders = 'prefs.folders';
  static const String currentFolder = 'prefs.currentFolder';
  static const String fitMode = 'prefs.readerFitMode';
  static const String twoPage = 'prefs.readerTwoPage';

  static const String favorites = 'prefs.favorites';

  static const String folderAliasesJson = 'prefs.folderAliasesJson';
  static const String folderTileMode = 'prefs.folderTileMode';

  /// json map: { "<MediaItem.id>": ["tag1","tag2", ...] }
  static const String tagsJson = 'prefs.tagsJson';
}

class _FolderNavState {
  final FolderHandle folder;
  final int pageIndex;
  const _FolderNavState(this.folder, this.pageIndex);
}

class GalleryGridPage extends StatefulWidget {
  final MediaRepository repo;
  final TagService tagService;

  const GalleryGridPage({
    super.key,
    required this.repo,
    required this.tagService,
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
  DateTime _lastProgressUi = DateTime.fromMillisecondsSinceEpoch(0);

  bool _thumbsEnabled = true;

  // --- スクロール中はサムネ生成を止める ---
  Timer? _thumbResumeDebounce;

  // --- フォルダ表紙�Eレビュー�E�LRUキャチE��ュ + 同時実行数制陁E---
  final LinkedHashMap<String, Uint8List?> _folderPreviewCache = LinkedHashMap();
  int _folderPreviewCacheBytes = 0;
  static const int _folderPreviewCacheMaxEntries = 120;
  static const int _folderPreviewCacheMaxBytes = 24 * 1024 * 1024; // 24MB

  final Map<String, Future<Uint8List?>> _folderPreviewInFlight = {};

  int _folderPreviewActive = 0;
  final List<Completer<void>> _folderPreviewWaiters = [];

  String? _libraryRootRaw;

  String _normPath(String p) => p.replaceAll('/', '\\').toLowerCase();

  bool _isInLibraryItem(MediaItem item) {
    if (_libraryRootRaw == null) return false;
    final id = _normPath(item.id);
    final root = _normPath(_libraryRootRaw!);
    return id == root || id.startsWith('$root\\');
  }

  bool get _isCurrentFolderInsideLibrary {
    if (_currentFolderRaw == null || _libraryRootRaw == null) return false;
    final cur = _normPath(_currentFolderRaw!);
    final root = _normPath(_libraryRootRaw!);
    return cur == root || cur.startsWith('$root\\');
  }

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
    // null も「中身なし」キャチE��ュとして扱ぁE��同じ探索を繰り返さなぁE��E
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
  final ExternalShareService _externalShareService = ExternalShareService();
  StreamSubscription<ExternalSharePayload>? _externalShareSub;
  List<MediaItem> _pendingSharedItems = const [];
  bool _pendingSharedNeedsFolderHelp = false;

  String _parentDirOfFullPath(String fullPath) {
    // Windowsでの"C:\a\b\c.jpg" / "C:/a/b/c.jpg" どちらも対忁E
    final p = fullPath.replaceAll('/', '\\');
    final idx = p.lastIndexOf('\\');
    if (idx <= 0) return p; // 念のためね
    return p.substring(0, idx);
  }

  Set<String> _favorites = <String>{};

  // tags�E�タグID付け�E�E
  Map<String, List<String>> _tagsById = <String, List<String>>{};

  _MainPage _page = _MainPage.home; // 起動時はホ�Eム�E�ここでどこを起動するか持E��してぁE��。！E

  // 褁E��フォルダ
  List<String> _foldersRaw = const []; // 登録済みフォルダ一覧�E�Eaw�E�E
  String? _currentFolderRaw; // 現在選択！Eaw�E�E

  // 表示設定（永続化�E�E
  ReaderFitMode _fitMode = ReaderFitMode.vertical;
  bool _twoPage = false;

  // ホ�Eム画面検索 (すべてのフォルダを参照)
  final TextEditingController _homeSearchCtrl = TextEditingController();
  String _homeQuery = '';
  bool _homeSearching = false;
  List<MediaItem> _homeSearchResults = const [];

  // 検索欁E�E力�Eた�Eに全フォルダ検索が動く�Eを防ぁE
  Timer? _homeSearchDebounce;

  // Home検索用、DBから引いたタグキャチE��ュ�E�EtemId -> tagNames�E�E
  Map<String, List<String>> _dbTagsByItemId = <String, List<String>>{};

  // フォルダ階層ナビ�E�ギャラリー冁E��E
  final List<_FolderNavState> _dirStack = <_FolderNavState>[];

  bool get _canGoUp => _dirStack.isNotEmpty;
  

  Future<void> _enterFolder(MediaItem folderItem) async { 
    if (_folder == null) return;  

    // ぁE��見てぁE��フォルダ + そ�E時�Eペ�Eジを積�E積�E
    _dirStack.add(_FolderNavState(_folder!, _galleryPageIndex));

    // 入った�Eは従来通りペ�Eジ1から
    await _loadFolder(FolderHandle(folderItem.id), saveAsLast: false, pageIndex: 0);
  }

  Future<void> _goUpFolder() async {
    if (_dirStack.isEmpty) return;
    final prev = _dirStack.removeLast();

    // 戻る時は「�Eのフォルダ」かつ「�Eのペ�Eジ」に復帰
    await _loadFolder(prev.folder, saveAsLast: false, pageIndex: prev.pageIndex);
  }

  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  List<MediaItem> _filteredItems = const [];

  _SortMode _sortMode = _SortMode.name;

  // raw -> 表示吁E
  Map<String, String> _folderAliases = <String, String>{};

  // 全フォルダを監視、お気に入り表示用
  final Map<String, List<MediaItem>> _folderItemsCache = {};
  List<MediaItem> _favoriteItemsAll = const [];
  bool _loadingFavAll = false;

  // Home検索用�E��E帰�E�ファイルのみ�E�E
  final Map<String, List<MediaItem>> _folderItemsCacheRecursive = {};

  // ---- 褁E��選択モーチE----
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

  // TabControllerのlistenerを二重登録しなぁE��めE
  bool _tabListenerInstalled = false;

  //ID 変種生�E
  Set<String> _idVariants(String id) {
    final s = <String>{id};

    // Windows用
    s.add(id.replaceAll('/', '\\'));
    s.add(id.replaceAll('\\', '/'));

    // Windows用にどっちでも拾える
    final lower = id.toLowerCase();
    s.add(lower);
    s.add(lower.replaceAll('/', '\\'));
    s.add(lower.replaceAll('\\', '/'));

    return s;
  }

  // ---- サイドバー�E�作老E��グ一覧 ----
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
      _rebuildTagCountCache(); // 件数更新
    } finally {
      if (mounted) setState(() => _loadingArtistTags = false);
    }
  }

  void _rebuildTagCountCache() {
    // 既に読み込んだフォルダ刁E��けで件数を作る�E�未ロード�Eは0になる！E
    final map = <String, int>{};

    for (final raw in _foldersRaw) {
      final items = _folderItemsCache[raw] ?? const <MediaItem>[];
      for (final it in items) {
        final tags = _dbTagsByItemId[it.id] ?? const <String>[];
        for (final t in tags) {
          final key = t.toLowerCase();
          map[key] = (map[key] ?? 0) + 1;
        }
      }
    }

    setState(() => _tagCountCache = map);
  }

  Future<void> _openTagGalleryFromDrawer(String tagName) async {
    Navigator.pop(context);

    // タグ検索として検索結果ペ�Eジへ�E�既存�E検索グリチE��を�E利用�E�E
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
    _externalShareSub = _externalShareService.payloads.listen((payload) {
      _handleExternalSharePayload(payload);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reloadArtistTagMasters();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final payload = await _externalShareService.takeInitialPayload();
      if (payload != null) {
        await _handleExternalSharePayload(payload);
      }
    });
  }

  Future<void> _applySearchFilterDb() async {
    final q = _query.trim();

    if (q.isEmpty) {
      setState(() => _filteredItems = _items);
      return;
    }

    // 形弁E key:value
    final idx = q.indexOf(':');
    if (idx > 0) {
      final key = q.substring(0, idx).trim().toLowerCase();
      final value = q.substring(idx + 1).trim();
      if (value.isNotEmpty) {
        TagCategory? cat;
        if (key == 'artist') cat = TagCategory.artist;
        if (key == 'type') cat = TagCategory.mediaType;
        if (key == 'series') cat = TagCategory.series;
        if (key == 'character') cat = TagCategory.character;

        if (cat != null) {
          final folderRaw = _currentFolderRaw!;
          final ids = await widget.tagService.findItemIdsByTag(
            folderRaw: folderRaw,
            category: cat,
            name: value,
            partial: true,
          );

          final idSet = ids.toSet();
          final filtered = _items.where((it) => idSet.contains(it.id)).toList();
          if (!mounted) return;
          setState(() => _filteredItems = filtered);
          return;
        }
      }
    }
    final lower = q.toLowerCase();
    final filtered = _items
        .where((it) => it.displayName.toLowerCase().contains(lower))
        .toList();

    setState(() => _filteredItems = filtered);
  }

  Future<void> _loadPrefsAndAutoOpenFolder() async {
    final prefs = await SharedPreferences.getInstance();

    // folder 表示名を格紁E
    Map<String, String> aliases = <String, String>{};
    final aliasesJson = prefs.getString(_PrefsKeys.folderAliasesJson);
    if (aliasesJson != null && aliasesJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(aliasesJson);
        if (decoded is Map) {
          for (final e in decoded.entries) {
            final k = e.key?.toString();
            final v = e.value?.toString();
            if (k != null && v != null) aliases[k] = v;
          }
        }
      } catch (_) {}
    }

    // favorites�E�お気に入り！E
    final favList =
        prefs.getStringList(_PrefsKeys.favorites) ?? const <String>[];

    // tags�E�タグ�E�E
    _tagsById = _decodeTags(prefs.getString(_PrefsKeys.tagsJson));

    // 表示設宁E
    final fitIndex = prefs.getInt(_PrefsKeys.fitMode);
    final two = prefs.getBool(_PrefsKeys.twoPage);

    // folders フォルダー
    List<String> folders =
        prefs.getStringList(_PrefsKeys.folders) ?? const <String>[];
    String? current = prefs.getString(_PrefsKeys.currentFolder);

    // もし、lastFolderRaw が残ってぁE��めEfolders に入れる
    if (folders.isEmpty) {
      final legacy = prefs.getString(_PrefsKeys.lastFolderRaw);
      if (legacy != null && legacy.isNotEmpty) {
        if (Platform.isWindows) {
          folders = <String>[legacy];
          current = legacy;
          await prefs.setStringList(_PrefsKeys.folders, folders);
          await prefs.setString(_PrefsKeys.currentFolder, legacy);
        } else {
          // Android用
          await prefs.remove(_PrefsKeys.lastFolderRaw);
        }
      }
    }

    // 保管庫を最初から登録済みに
    final lib = await widget.repo.getAppLibraryFolder();
    final libRaw = lib.raw;
    _libraryRootRaw = libRaw;

    // folders に存在し無ければ先頭に入れる
    if (!folders.contains(libRaw)) {
      folders = <String>[libRaw, ...folders];
      await prefs.setStringList(_PrefsKeys.folders, folders);
    }

    // 保管庫に表示名も無ければ付丁E
    if (!aliases.containsKey(libRaw) || aliases[libRaw]!.trim().isEmpty) {
      aliases[libRaw] = '保管庫';
      await prefs.setString(_PrefsKeys.folderAliasesJson, jsonEncode(aliases));
    }

    // 実在チェチE��
    final existsFolders = <String>{};

    for (final p in folders) {
      // SAF, Treeuriはそ�Eまま有効
      if (p.startsWith('content://')) {
        existsFolders.add(p);
        continue;
      }

      // Directory.exists で存在を判宁E
      try {
        final d = Directory(p);
        if (await d.exists()) existsFolders.add(p);
      } catch (_) {}
    }

    // current の整合性�E�無ければ保管庫をデフォルトとする�E�E
    if (current == null || !existsFolders.contains(current)) {
      if (existsFolders.contains(libRaw)) {
        current = libRaw;
      } else {
        current = existsFolders.isNotEmpty ? existsFolders.first : null;
      }
    }

    //  実在しなぁE��ォルダが消えた場合�E prefs も更新しておく
    await prefs.setStringList(_PrefsKeys.folders, existsFolders.toList());

    if (current != null) {
      await prefs.setString(_PrefsKeys.currentFolder, current);
    } else {
      await prefs.remove(_PrefsKeys.currentFolder);
    }

    if (!aliases.containsKey(libRaw) || aliases[libRaw]!.trim().isEmpty) {
      aliases[libRaw] = '保管庫';
    }
    if (!folders.contains(libRaw)) {
      folders = List<String>.from(folders)..insert(0, libRaw);
      await prefs.setStringList(_PrefsKeys.folders, folders);
    }

    final modeIndex = prefs.getInt(_PrefsKeys.folderTileMode);
    if (modeIndex != null &&
        modeIndex >= 0 &&
        modeIndex < FolderTileMode.values.length) {
      _folderTileMode = FolderTileMode.values[modeIndex];
    }

    // 反映
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

    // 選択中フォルダをローチE
    await _loadFolder(FolderHandle(current), saveAsLast: false);
  }

  Future<void> _deleteItemsWithWarning(List<MediaItem> targets) async {
    if (targets.isEmpty) return;

    final onlyLibrary = targets.every(_isInLibraryItem);
    if (!onlyLibrary) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('�ۊǌɓ��̍��ڂ̂ݍ폜�ł��܂�')),
      );
      return;
    }

    final names = targets.take(3).map((e) => e.displayName).join('\n');
    final more = targets.length > 3 ? '\n�� ${targets.length - 3} ��' : '';

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('�폜���܂����H'),
        content: Text(
          targets.length == 1
              ? '�u${targets.first.displayName}�v��ۊǌɂ���폜���܂��B\n���̑���͌��ɖ߂��܂���B'
              : '���� ${targets.length} ����ۊǌɂ���폜���܂��B\n$names$more\n\n���̑���͌��ɖ߂��܂���B',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('�L�����Z��'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('�폜'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    int deleted = 0;
    for (final item in targets) {
      final ok = await widget.repo.deleteItem(item);
      if (!ok) continue;

      if (item.kind == MediaKind.folder) {
        await widget.tagService.deleteItemsUnderPathPrefix(item.id);
      } else {
        await widget.tagService.deleteItemsByIds([item.id]);
      }

      _favorites.remove(item.id);
      _selectedIds.remove(item.id);
      deleted++;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _PrefsKeys.favorites,
      _favorites.toList(growable: false),
    );

    if (!mounted) return;

    await _loadFolder(
      FolderHandle(_currentFolderRaw!),
      saveAsLast: false,
      pageIndex: 0,
    );
    await _refreshAllFavoritesItems();
    if (_homeQuery.trim().isNotEmpty) {
      await _runHomeSearch();
    }

    setState(() {
      if (_selectedIds.isEmpty) _selectMode = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('�폜���܂���: $deleted / ${targets.length} ��')),
    );
  }

  Future<void> _deleteSelectedItems() async {
    final targets = _selectedFrom(_filteredItems);
    await _deleteItemsWithWarning(targets);
  }

  Future<void> _saveFolderTileMode(FolderTileMode m) async {
    setState(() => _folderTileMode = m);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_PrefsKeys.folderTileMode, m.index);
  }

  Future<Uint8List?> _getFolderPreviewBytes(MediaItem folderItem) {
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
          if (it.kind == MediaKind.pdf) return it;
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

  Map<String, List<String>> _decodeTags(String? raw) {
    if (raw == null || raw.isEmpty) return <String, List<String>>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final Map<String, List<String>> map = <String, List<String>>{};
        for (final entry in decoded.entries) {
          final key = entry.key?.toString();
          final val = entry.value;
          if (key == null) continue;
          if (val is List) {
            map[key] = val.map((e) => e.toString()).toList(growable: false);
          }
        }
        return map;
      }
    } catch (_) {}
    return <String, List<String>>{};
  }

  List<String> _tagsFor(MediaItem item) =>
      _tagsById[item.id] ?? const <String>[];

  Future<void> _reloadTags() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(
      () => _tagsById = _decodeTags(prefs.getString(_PrefsKeys.tagsJson)),
    );
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
          _folderItemsCacheRecursive[raw] = list;
        } catch (_) {
          _folderItemsCacheRecursive[raw] = const <MediaItem>[];
        }
      }

      final all = <MediaItem>[];
      for (final raw in _foldersRaw) {
        final list = _folderItemsCacheRecursive[raw] ?? const <MediaItem>[];
        all.addAll(list);
      }

      final idSet = <String>{};
      for (final it in all) {
        idSet.addAll(_idVariants(it.id));
      }
      final ids = idSet.toList(growable: false);

      final rawMap = await widget.tagService.getTagNamesByItemIds(ids);

      final expanded = <String, List<String>>{};
      rawMap.forEach((k, v) {
        for (final vv in _idVariants(k)) {
          expanded[vv] = v;
        }
      });

      _dbTagsByItemId = expanded;

      final filtered = all.where((e) => _matchHomeQuery(e, q)).toList(growable: false);

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
      print('[HOME SEARCH] error: $e\n$st');

      if (!mounted) return;
      setState(() {
        _homeSearching = false;
        _homeSearchResults = const [];
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Home�����ŃG���[: $e')),
      );
    }
  }
  Future<void> _organizeLibrary() async {
    try {
      final lib = await widget.repo.getAppLibraryFolder();
      final moved = await widget.tagService.organizeAppLibrary(
        libraryRoot: lib.raw,
      );

      if (!mounted) return;

      // 表示更新�E�今見てるフォルダが保管庫配下ならリローチE
      if (_currentFolderRaw != null && _currentFolderRaw!.startsWith(lib.raw)) {
        await _loadFolder(FolderHandle(_currentFolderRaw!), saveAsLast: false);
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('保管庫整琁E 移勁E${moved.length} 件')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('保管庫整琁E��失敁E $e')));
    }
  }

  Future<void> _openExternalPdf() async {
    try {
      final item = await widget.repo.pickSinglePdf();
      if (item == null || !mounted) return;
      await _openExternalItems([item]);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to open external PDF: $e')),
      );
    }
  }

  Future<void> _pickSharedFilesToLibrary() async {
    try {
      final items = await widget.repo.pickExternalMediaFiles(
        allowMultiple: true,
        includeImages: true,
        includePdf: true,
      );
      if (items.isEmpty || !mounted) return;

      final imported = await _importSelectedToLibrary(items);
      if (!mounted) return;
      if (imported > 0) {
        setState(() {
          _pendingSharedItems = const [];
          _pendingSharedNeedsFolderHelp = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to pick files: $e')),
      );
    }
  }

  Future<void> _importPendingSharedFilesToLibrary() async {
    if (_pendingSharedItems.isEmpty) {
      if (!mounted) return;
      final message = _pendingSharedNeedsFolderHelp
          ? 'Shared folders may not arrive directly. Use Add External Folder.'
          : 'No shared files are waiting to import.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
      return;
    }

    final imported = await _importSelectedToLibrary(_pendingSharedItems);
    if (!mounted) return;
    if (imported > 0) {
      setState(() {
        _pendingSharedItems = const [];
        _pendingSharedNeedsFolderHelp = false;
      });
    }
  }

  Future<void> _handleExternalSharePayload(ExternalSharePayload payload) async {
    if (payload.isEmpty) return;

    try {
      final items = payload.rawItems.isEmpty
          ? const <MediaItem>[]
          : await widget.repo.resolveExternalItems(payload.rawItems);

      if (!mounted) return;

      if (items.isEmpty) {
        setState(() {
          _pendingSharedItems = const [];
          _pendingSharedNeedsFolderHelp = payload.hasUnsupportedPayload;
        });

        final message = payload.hasUnsupportedPayload
            ? 'Shared folders may not arrive directly. Use Add External Folder.'
            : 'No supported shared files were found.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
        return;
      }

      if (items.length == 1) {
        await _showSingleSharedItemDialog(items.first);
        return;
      }

      setState(() {
        _pendingSharedItems = items;
        _pendingSharedNeedsFolderHelp = payload.hasUnsupportedPayload;
      });

      final extra = payload.hasUnsupportedPayload
          ? ' Some folders may need Add External Folder.'
          : '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Received ${items.length} shared files.$extra')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to handle shared files: $e')),
      );
    }
  }

  Future<void> _openExternalItems(
    List<MediaItem> items, {
    int initialIndex = 0,
  }) async {
    if (items.isEmpty || !mounted) return;

    final mediaOnly = items
        .where((item) => item.kind != MediaKind.folder)
        .toList(growable: false);
    if (mediaOnly.isEmpty) return;

    final safeIndex = initialIndex < 0 || initialIndex >= mediaOnly.length
        ? 0
        : initialIndex;

    await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ImageDetailPage(
          repo: widget.repo,
          tagService: widget.tagService,
          items: mediaOnly,
          initialIndex: safeIndex,
          initialPdfPage: 1,
        ),
      ),
    );
  }

  Future<void> _showSingleSharedItemDialog(MediaItem item) async {
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(item.kind == MediaKind.pdf ? 'Shared PDF' : 'Shared File'),
        content: Text(item.displayName),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'import'),
            child: const Text('Import'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'open'),
            child: const Text('Open Now'),
          ),
        ],
      ),
    );

    if (!mounted || action == null || action == 'cancel') return;

    if (action == 'open') {
      await _openExternalItems([item]);
      return;
    }

    final imported = await _importSelectedToLibrary([item]);
    if (!mounted) return;
    if (imported > 0) {
      setState(() {
        _pendingSharedItems = const [];
        _pendingSharedNeedsFolderHelp = false;
      });
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
        ? 'Not selected'
        : _folderLabel(_currentFolderRaw!);

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Actions',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text('Folders: $folderCount'),
                Text('Current folder: $currentLabel'),
                if (_pendingSharedItems.isNotEmpty || _pendingSharedNeedsFolderHelp)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      _pendingSharedItems.isNotEmpty
                          ? 'Pending shared files: ${_pendingSharedItems.length}'
                          : 'Shared folders may need SAF folder selection.',
                    ),
                  ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ElevatedButton.icon(
                      onPressed: _addFolder,
                      icon: const Icon(Icons.create_new_folder_outlined),
                      label: const Text('Add External Folder'),
                    ),
                    ElevatedButton.icon(
                      onPressed: _openExternalPdf,
                      icon: const Icon(Icons.picture_as_pdf_outlined),
                      label: const Text('Open External PDF'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _importPendingSharedFilesToLibrary,
                      icon: const Icon(Icons.archive_outlined),
                      label: const Text('Import Shared Files'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _pickSharedFilesToLibrary,
                      icon: const Icon(Icons.upload_file_outlined),
                      label: const Text('Pick Files To Import'),
                    ),
                    OutlinedButton.icon(
                      onPressed: (_currentFolderRaw == null)
                          ? null
                          : () => setState(() => _page = _MainPage.gallery),
                      icon: const Icon(Icons.grid_view),
                      label: const Text('Open Gallery'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _refreshAllFavoritesItems,
                      icon: const Icon(Icons.star),
                      label: const Text('Refresh Favorites'),
                    ),
                  ],
                ),
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
        child: Text('Enter a title, tag, or #tag in Home search.'),
      );
    }

    if (_homeSearchResults.isEmpty) {
      return const Center(child: Text('該当するアイチE��がありません'));
    }

    // Home検索結果は全フォルダだから、_items�E�現在フォルダ�E�を使わず
    // 検索結果リストをそ�Eまま渡して詳細ペ�Eジで前後移動できるようにする
    return _buildGridFromList(_homeSearchResults, showFolderLabel: true);
  }

  // --------------------
  // フォルダ表示名設宁E
  // --------------------
  String _basename(String raw) {
    String s = raw;
    //　アンドロイド対応がめE��こしぁE�Eで�E�－４�E頁E��通りにめE��、E
    // 1) SAFの content://... の場合�E tree/document の次のsegs�E�セグメント）を取り出ぁE
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
          s = encoded; // 侁E primary%3ADocuments%2Fexperiment�E�Endroidの場合、実験フォルダを使ぁE��E
        }
      } catch (_) {
        // 失敗したら s=raw のままフォールバック
      }
    }

    // 2) 「primary%3A...」みたいにエンコード文字�Eだけ保存されてぁE��ケースにも対忁E
    //    二重もあり得るので最大2回回す、E
    for (int i = 0; i < 2; i++) {
      if (!s.contains('%')) break;
      try {
        s = Uri.decodeComponent(s);
      } catch (_) {
        break;
      }
    }

    // 3) "primary:" などボリューム名を落とぁEↁE最後�Eパス要素だけにする
    final colon = s.indexOf(':');
    if (colon >= 0) s = s.substring(colon + 1);

    s = s.replaceAll('\\', '/');
    final slash = s.lastIndexOf('/');
    if (slash >= 0) s = s.substring(slash + 1);

    // 4) 空なら�Eの raw を返す
    return s.trim().isEmpty ? raw : s.trim();
  }

  String _folderLabel(String raw) {
    final a = _folderAliases[raw];
    if (a != null && a.trim().isNotEmpty) return a.trim();
    return _basename(raw);
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
          title: const Text('Rename Folder'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Display Name',
              hintText: 'Example: Manga / Work / Artist',
            ),
            onSubmitted: (_) => Navigator.of(ctx).pop(controller.text),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text),
              child: const Text('Save'),
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
      });
    } else {
      await _loadFolder(FolderHandle(folderRaw), saveAsLast: false);
      _folderItemsCache[folderRaw] = _items;
    }

    final idx = _items.indexWhere((e) => e.id == item.id);
    if (idx < 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File was not found.')),
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
      await _reloadFavorites();
      await _refreshAllFavoritesItems();
      if (_homeQuery.trim().isNotEmpty) {
        await _runHomeSearch();
      }
    }
  }

  String _folderLabelForItem(MediaItem item) {
    final itemNorm = _normalizePath(item.id);

    String? bestMatchRaw;
    var bestLen = -1;

    for (final raw in _foldersRaw) {
      final folderNorm = _normalizePath(raw);
      final ok = itemNorm == folderNorm || itemNorm.startsWith('\\');
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
    // Windows用
    var s = p.replaceAll('/', '\\');
    while (s.endsWith('\\')) {
      s = s.substring(0, s.length - 1);
    }
    return s.toLowerCase();
  }

  // --------------------
  // フォルダー管琁E
  // --------------------
  Future<void> _saveLastFolder(FolderHandle folder) async {
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
      _filteredItems = const [];
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
        _filteredItems = res.items; // ←検索は「�Eージ冁E��でOKならこれでOK
        _loading = false;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) async {
       // 一覧を�Eに描画させてからサムネ開姁E
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
        SnackBar(content: Text('�ǂݍ��ݎ��s: ')),
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
      _filteredItems = const [];
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
        _filteredItems = res.items;
        _loading = false;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (!mounted) return;
        setState(() => _thumbsEnabled = true);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('�y�[�W�ǂݍ��ݎ��s: ')),
      );
    }
  }

  Future<void> _persistFolders() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_PrefsKeys.folders, _foldersRaw);
    if (_currentFolderRaw == null) {
      await prefs.remove(_PrefsKeys.currentFolder);
    } else {
      await prefs.setString(_PrefsKeys.currentFolder, _currentFolderRaw!);
    }
  }

  Future<void> _addFolder() async {
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
    try {
      final count = await widget.repo.importIntoFolder(folder);
      if (!mounted) return;

      if (count > 0) {
        await _loadFolder(folder, saveAsLast: false);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('�ǉ����܂���:  ��')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('�ǉ��Ɏ��s: ')),
      );
    }
  }

  Future<void> _importToLibraryAndTag() async {
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

      final importedCount = await widget.repo.importIntoFolder(lib);
      if (!mounted) return;

      if (importedCount <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('��荞�݂͂���܂���ł���')),
        );
        return;
      }

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
          SnackBar(content: Text('�ۊǌɂ֎�荞��:  ���i�����擾�Ȃ��j')),
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
      _rebuildTagCountCache();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('�ۊǌɂ֎�荞��:  ���i�^�O�t���Ώ�:  ���j')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('��荞�ݎ��s: ')),
      );
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
    _externalShareSub?.cancel();
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
        // ✁Efolder は常に残しつつ、pdf を表示
        out = out.where((e) => e.kind == MediaKind.folder || e.kind == MediaKind.pdf);
      } else {
        // ✁Efolder は常に残しつつ、image を表示
        out = out.where((e) => e.kind == MediaKind.folder || e.kind == MediaKind.image);
      }
    }

    final qRaw = _query.trim().toLowerCase();
    if (qRaw.isNotEmpty) {
      // 空白区刁E��で褁E��条件:
      // - "#tag" : タグ一致�E�部刁E��致�E�E　　　　　#のあとに一致するも�Eがある�EぁE
      // - "word" : ファイル吁Eor タグに部刁E��致　#のあとでも普通�E斁E��でもとにかくあてはまるものがある�EぁE
      final tokens = qRaw
          .split(RegExp(r'\s+'))
          .where((e) => e.isNotEmpty)
          .toList();

      out = out.where((item) {
        final name = item.displayName.toLowerCase();
        final tags = _tagsFor(
          item,
        ).map((e) => e.toLowerCase()).toList(growable: false);

        bool matchToken(String t) {
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

  /// 「タグなし」タブ用: フォルダは除外し、タグぁEつも付いてぁE��ぁE��僁EPDFのみ表示
  List<MediaItem> _applyUntagged(List<MediaItem> input) {
    final base = _applyFilter(input, pdfOnly: null);
    return base.where((e) => e.kind != MediaKind.folder && e.tags.isEmpty).toList();
  }

  // ---- AppBar overflow menus ----
  Future<void> _onHomeMenuSelected(_HomeMenuAction action) async {
    switch (action) {
      case _HomeMenuAction.addFolder:
        _addFolder();
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
            ),
          ),
        );
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
        _addFolder();
        return;
      case _GalleryMenuAction.addFile:
        if (_currentFolderRaw == null) return;
        _importToCurrentFolder();
        return;
      case _GalleryMenuAction.exportPdf:
        await _exportCurrentFolderImagesToPdf();
        return;
      case _GalleryMenuAction.organizeLibrary:
        _organizeLibrary();
        return;
      case _GalleryMenuAction.folderTileMode:
        await _showFolderTileModeDialog(); // ←追加
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
            title: Text('保管庫へ取り込み'),
          ),
        ),
        PopupMenuItem(
          value: _HomeMenuAction.artistTagIndex,
          child: ListTile(
            leading: Icon(Icons.person),
            title: Text('アーチE��ストタグ一覧'),
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
            title: Text('Search Results Gallery'),
          ),
        ),
      ],
    );
  }

  PopupMenuButton<_GalleryMenuAction> _buildGalleryOverflowMenu() {
    return PopupMenuButton<_GalleryMenuAction>(
      tooltip: 'Menu',
      icon: const Icon(Icons.more_vert),
      onSelected: _onGalleryMenuSelected,
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: _GalleryMenuAction.folderTileMode,
          child: ListTile(
            leading: Icon(Icons.folder_open_outlined),
            title: Text('Folder Display'),
          ),
        ),
        const PopupMenuItem(
          value: _GalleryMenuAction.addFolder,
          child: ListTile(
            leading: Icon(Icons.create_new_folder_outlined),
            title: Text('Add Folder'),
          ),
        ),
        PopupMenuItem(
          value: _GalleryMenuAction.addFile,
          enabled: _currentFolderRaw != null,
          child: const ListTile(
            leading: Icon(Icons.upload_file_outlined),
            title: Text('Add File'),
          ),
        ),
        const PopupMenuItem(
          value: _GalleryMenuAction.organizeLibrary,
          child: ListTile(
            leading: Icon(Icons.auto_awesome_mosaic_outlined),
            title: Text('Organize Library'),
          ),
        ),
        const PopupMenuItem(
          value: _GalleryMenuAction.exportPdf,
          child: ListTile(
            leading: Icon(Icons.picture_as_pdf_outlined),
            title: Text('Export Images To PDF'),
          ),
        ),
        const PopupMenuItem(
          value: _GalleryMenuAction.goHome,
          child: ListTile(
            leading: Icon(Icons.home_outlined),
            title: Text('Home'),
          ),
        ),
      ],
    );
  }

  Future<void> _exportCurrentFolderImagesToPdf() async {
    if (_loading) return;
    final folder = _folder;
    if (folder == null) return;

    final allItems = await widget.repo.listMedia(folder);
    final images = _applyFilter(allItems, pdfOnly: false)
        .where((e) => e.kind == MediaKind.image)
        .toList(growable: false);

    if (images.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No images found.')),
      );
      return;
    }

    final folderName = _currentFolderRaw == null
        ? 'export'
        : _folderLabel(_currentFolderRaw!);

    int done = 0;
    final total = images.length;
    StateSetter? progressSetState;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Creating PDF...'),
        content: StatefulBuilder(
          builder: (context, setD) {
            progressSetState = setD;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: total == 0 ? null : done / total),
                const SizedBox(height: 12),
                Text('$done / $total'),
                const SizedBox(height: 8),
                const Text('Exporting all images in the current folder.'),
              ],
            );
          },
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
          progressSetState?.call(() {});
        },
      );

      if (!mounted) return;
      Navigator.pop(context);

      if (created == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Save canceled.')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('PDF saved.')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('PDF export failed: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _showFolderTileModeDialog() async {
    final mode = await showDialog<FolderTileMode>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Folder Display'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, FolderTileMode.labelOnly),
            child: const Text('Label Only'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, FolderTileMode.preview),
            child: const Text('Preview'),
          ),
        ],
      ),
    );

    if (mode == null) return;
    _saveFolderTileMode(mode);
  }

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
        ? 'None'
        : _folderLabel(_currentFolderRaw!);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Media Viewer', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Current folder: $currentLabel',
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
          title: const Text('Home'),
          selected: _page == _MainPage.home,
          onTap: () {
            _closeSidebar();
            _exitSelectMode();
            setState(() => _page = _MainPage.home);
          },
        ),
        ListTile(
          leading: const Icon(Icons.grid_view),
          title: const Text('Gallery'),
          selected: _page == _MainPage.gallery,
          onTap: () {
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
        _sidebarSectionLabel('Artist Tags'),
        if (_loadingArtistTags)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: LinearProgressIndicator(),
          )
        else
          ExpansionTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('Artists'),
            children: [
              if (_artistTagMasters.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Text('No artist tags yet.'),
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
        _sidebarSectionLabel('Display'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: InputDecorator(
            decoration: const InputDecoration(
              labelText: 'Fit Mode',
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
                    child: Text('Vertical'),
                  ),
                  DropdownMenuItem(
                    value: ReaderFitMode.horizontal,
                    child: Text('Horizontal'),
                  ),
                  DropdownMenuItem(
                    value: ReaderFitMode.contain,
                    child: Text('Contain'),
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
          title: const Text('Two Page'),
          value: _twoPage,
          onChanged: (v) async {
            setState(() => _twoPage = v);
            await _saveTwoPage(v);
          },
        ),
        const Divider(),
        _sidebarSectionLabel('Folders'),
        ListTile(
          leading: const Icon(Icons.create_new_folder_outlined),
          title: const Text('Add Folder'),
          onTap: () async {
            _closeSidebar();
            await _addFolder();
          },
        ),
        if (_foldersRaw.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text('No registered folders.'),
          )
        else ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 6, 16, 6),
            child: Text('Tap to switch, trash to remove.'),
          ),
          for (final raw in _foldersRaw)
            ListTile(
              leading: Icon(
                raw == _currentFolderRaw ? Icons.folder : Icons.folder_outlined,
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
                    tooltip: 'Rename',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () async {
                      _closeSidebar();
                      await _renameFolder(raw);
                    },
                  ),
                  IconButton(
                    tooltip: 'Remove Folder',
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
              'Registered folders and the current selection are restored on next launch when available.',
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
    if (_page == _MainPage.home) {
      return Scaffold(
        drawer: _isWideLayout(context) ? null : _buildSidebar(),
        appBar: AppBar(
          title: const Text('Home'),
          actions: [_buildHomeOverflowMenu()],
        ),
        body: _withSidebar(context, _buildHomeBody()),
      );
    }

    if (_page == _MainPage.search) {
      return Scaffold(
        drawer: _isWideLayout(context) ? null : _buildSidebar(),
        appBar: AppBar(
          title: const Text('Search Results'),
          actions: _selectMode
              ? [
                  IconButton(
                    tooltip: 'Clear Selection',
                    onPressed: _exitSelectMode,
                    icon: const Icon(Icons.close),
                  ),
                  IconButton(
                    tooltip: 'Select All',
                    onPressed: () => _selectAll(_homeSearchResults),
                    icon: const Icon(Icons.select_all),
                  ),
                  IconButton(
                    tooltip: 'Clear',
                    onPressed: _clearSelection,
                    icon: const Icon(Icons.clear_all),
                  ),
                  IconButton(
                    tooltip: 'Add Tag To Selection',
                    onPressed: () {
                      final targets = _selectedFrom(_homeSearchResults);
                      _bulkAddTagToItems(targets);
                    },
                    icon: const Icon(Icons.label_outline),
                  ),
                  IconButton(
                    tooltip: 'Import Selection To Library',
                    onPressed: () {
                      final targets = _selectedFrom(_homeSearchResults);
                      _importSelectedToLibrary(targets);
                    },
                    icon: const Icon(Icons.archive_outlined),
                  ),
                ]
              : [
                  IconButton(
                    tooltip: 'Home',
                    onPressed: () {
                      _exitSelectMode();
                      setState(() => _page = _MainPage.home);
                    },
                    icon: const Icon(Icons.home_outlined),
                  ),
                  IconButton(
                    tooltip: 'Gallery',
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

    return DefaultTabController(
      length: 3,
      child: Builder(
        builder: (context) {
          final tc = DefaultTabController.of(context);
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
                      tooltip: 'Up',
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () {
                        _exitSelectMode();
                        _goUpFolder();
                      },
                    )
                  : null,
              title: Text(
                _folder == null ? 'Gallery' : 'Gallery: ${_folderLabel(_folder!.raw)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              actions: _selectMode
                  ? [
                      IconButton(
                        tooltip: 'Clear Selection',
                        onPressed: _exitSelectMode,
                        icon: const Icon(Icons.close),
                      ),
                      IconButton(
                        tooltip: 'Select All',
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
                        tooltip: 'Clear',
                        onPressed: _clearSelection,
                        icon: const Icon(Icons.clear_all),
                      ),
                      IconButton(
                        tooltip: 'Add Tag To Selection',
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
                          final targets = _selectedFrom(view);
                          _bulkAddTagToItems(targets);
                        },
                        icon: const Icon(Icons.label_outline),
                      ),
                      IconButton(
                        tooltip: 'Import Selection To Library',
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
                          final targets = _selectedFrom(view);
                          _importSelectedToLibrary(targets);
                        },
                        icon: const Icon(Icons.archive_outlined),
                      ),
                      IconButton(
                        tooltip: 'Delete Selection',
                        onPressed: _deleteSelectedItems,
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ]
                  : [
                      _buildGalleryOverflowMenu(),
                    ],
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
                            hintText: 'Search title',
                            border: const OutlineInputBorder(),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(vertical: 10),
                            suffixIcon: (_query.trim().isEmpty)
                                ? null
                                : IconButton(
                                    tooltip: 'Clear',
                                    icon: const Icon(Icons.clear),
                                    onPressed: () {
                                      _searchCtrl.clear();
                                      setState(() => _query = '');
                                      _applySearchFilterDb();
                                    },
                                  ),
                          ),
                          onChanged: (v) => setState(() => _query = v),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: SizedBox(
                        height: 36,
                        child: Row(
                          children: [
                            const Text('Sort: '),
                            const SizedBox(width: 8),
                            DropdownButton<_SortMode>(
                              value: _sortMode,
                              items: const [
                                DropdownMenuItem(
                                  value: _SortMode.name,
                                  child: Text('Name'),
                                ),
                                DropdownMenuItem(
                                  value: _SortMode.updatedAt,
                                  child: Text('Updated'),
                                ),
                                DropdownMenuItem(
                                  value: _SortMode.addedAt,
                                  child: Text('Added'),
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
                    const TabBar(
                      isScrollable: true,
                      tabs: [
                        Tab(text: 'All'),
                        Tab(text: 'Untagged'),
                        Tab(text: 'Favorites'),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            body: _withSidebar(
              context,
              _folder == null
                  ? Center(
                      child: ElevatedButton(
                        onPressed: _addFolder,
                        child: const Text('Add Folder'),
                      ),
                    )
                  : _loading
                      ? const Center(child: CircularProgressIndicator())
                      : _items.isEmpty
                          ? const Center(child: Text('No images or PDFs found.'))
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
    // 空白は禁止
    if (t.contains(RegExp(r'\s'))) return null;
    return t;
  }

  String _categoryLabel(TagCategory c) {
    switch (c) {
      case TagCategory.artist:
        return 'Artist';
      case TagCategory.series:
        return 'Series';
      case TagCategory.mediaType:
        return 'Media Type';
      case TagCategory.character:
        return 'Character';
      case TagCategory.free:
        return 'Free';
    }
  }
  Future<void> _bulkAddTagToItems(List<MediaItem> targets) async {
    if (targets.isEmpty) return;

    final ctrl = TextEditingController();
    TagCategory category = TagCategory.free;

    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Tag'),
        content: StatefulBuilder(
          builder: (context, setStateDialog) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<TagCategory>(
                  value: category,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: const [
                    DropdownMenuItem(value: TagCategory.artist, child: Text('Artist')),
                    DropdownMenuItem(value: TagCategory.series, child: Text('Series')),
                    DropdownMenuItem(value: TagCategory.mediaType, child: Text('Media Type')),
                    DropdownMenuItem(value: TagCategory.character, child: Text('Character')),
                    DropdownMenuItem(value: TagCategory.free, child: Text('Free')),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setStateDialog(() => category = value);
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Tag'),
                ),
              ],
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Add'),
          ),
        ],
      ),
    );

    if (accepted != true) return;
    final name = _normalizeTagName(ctrl.text);
    if (name == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid tag without spaces.')),
      );
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
        Tag(name: name, category: category),
      );

      final ids = targets.map((item) => item.id).toList(growable: false);
      final got = await widget.tagService.getTagNamesByItemIds(ids);
      if (!mounted) return;
      setState(() {
        for (final entry in got.entries) {
          _dbTagsByItemId[entry.key] = entry.value;
        }
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added "$name" to ${targets.length} items.')),
      );
    } finally {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
  }

  Future<int> _importSelectedToLibrary(List<MediaItem> targets) async {
    if (targets.isEmpty) return 0;

    final lib = await widget.repo.getAppLibraryFolder();
    final before = await widget.repo.listMedia(lib);
    final beforeIds = before.map((item) => item.id).toSet();

    final imported = await widget.repo.importItemsIntoFolder(
      lib,
      targets,
      skipIfExists: true,
    );

    if (imported <= 0) {
      if (!mounted) return 0;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No new items were imported.')),
      );
      return 0;
    }

    final after = await widget.repo.listMedia(lib);
    final newItems = after
        .where((item) => item.kind != MediaKind.folder && !beforeIds.contains(item.id))
        .toList(growable: false);

    if (!mounted) return 0;

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
    return imported;
  }
  Widget _buildGrid(List<MediaItem> items, {bool showFolderLabel = false}) {
    if (items.isEmpty) {
      return const Center(child: Text('該当するアイチE��がありません'));
    }

     return Column(
      children: [
        // ☁E一番上にペ�Eジャ
        _buildPager(),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            child: GridView.builder(
              cacheExtent: 200, // 先読み抑制
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
  
                return Stack(
                  children: [
                    Positioned.fill(
                      child: InkWell(
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
                            await _loadFolder(FolderHandle(_currentFolderRaw!), saveAsLast: false, pageIndex: _galleryPageIndex);
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
                      ),
                    ),

                    if (_isInLibraryItem(item))
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Material(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(20),
                          child: PopupMenuButton<String>(
                            icon: const Icon(Icons.more_vert, size: 18, color: Colors.white),
                            onSelected: (v) async {
                              if (v == 'delete') {
                                await _deleteItemsWithWarning([item]);
                              }
                            },
                            itemBuilder: (context) => const [
                              PopupMenuItem<String>(
                                value: 'delete',
                                child: ListTile(
                                  leading: Icon(Icons.delete_outline),
                                  title: Text('保管庫から削除'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
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
                  child: Text('ペ�Eジ ${i + 1}'),
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
      return const Center(child: Text('該当するアイチE��がありません'));
    }

    return GridView.builder(
      cacheExtent: 200, // 先読み抑制
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

        return Stack(
          children: [
            Positioned.fill(
              child: InkWell(
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
                    await _loadFolder(FolderHandle(_currentFolderRaw!), saveAsLast: false, pageIndex: _galleryPageIndex);
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
              ),
            ),
        
            if (_isInLibraryItem(item))
              Positioned(
                top: 6,
                right: 6,
                child: Material(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                  child: PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert, size: 18, color: Colors.white),
                    onSelected: (v) async {
                      if (v == 'delete') {
                        await _deleteItemsWithWarning([item]);
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem<String>(
                        value: 'delete',
                        child: ListTile(
                          leading: Icon(Icons.delete_outline),
                          title: Text('保管庫から削除'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
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
    // ① 軽量モード：�Eレビューを一刁E��ばなぁE
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

      // ② プレビューモード：表紙を取得して表示
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
      
            // ✁Eselected overlay�E�ここで readThumbPair を呼ばなぁE��E
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
          // NOTE: _thumbsEnabled ぁEfalse の間�E FutureBuilder 自体を作らなぁE��E サムネ生成を開始しなぁE��E
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

          // 右上：PDFバッジ + ☁E
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

          // タイトル
          Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: _TitleChip(title: item.displayName, subtitle: subtitle),
          ),

          // 選択時
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
          // ここで失敗を出劁E
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





















