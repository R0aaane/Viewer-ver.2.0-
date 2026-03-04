import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, Platform;
import 'dart:typed_data';
import 'dart:collection';

import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../database/tag_service.dart';
import '../models/folder.dart';
import '../models/mediaItem.dart';
import '../models/tag.dart';
import '../database/pdf_export_service.dart';
import 'tag_assign_after_import.dart'; 

import '../repository/mediaRepository.dart';

import 'artistTagIndex.dart';
import 'detailImage.dart';

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
  labelOnly,      // フォルダアイコン＋名前だけ（最軽量）
  preview,        // フォルダ内の表紙プレビュー＋FOLDERバッジ（重め）
}

class _PrefsKeys {
  // 旧キー
  static const String lastFolderRaw = 'prefs.lastFolderRaw';

  // 複数フォルダ管理用
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

  // --- フォルダ表紙プレビュー：LRUキャッシュ + 同時実行数制限 ---
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
    // null も「中身なし」キャッシュとして扱う（同じ探索を繰り返さない）
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
    // Windowsでの"C:\a\b\c.jpg" / "C:/a/b/c.jpg" どちらも対応
    final p = fullPath.replaceAll('/', '\\');
    final idx = p.lastIndexOf('\\');
    if (idx <= 0) return p; // 念のためね
    return p.substring(0, idx);
  }

  Set<String> _favorites = <String>{};

  // tags（タグID付け）
  Map<String, List<String>> _tagsById = <String, List<String>>{};

  _MainPage _page = _MainPage.home; // 起動時はホーム（ここでどこを起動するか指定している。）

  // 複数フォルダ
  List<String> _foldersRaw = const []; // 登録済みフォルダ一覧（raw）
  String? _currentFolderRaw; // 現在選択（raw）

  // 表示設定（永続化）
  ReaderFitMode _fitMode = ReaderFitMode.vertical;
  bool _twoPage = false;

  // ホーム画面検索 (すべてのフォルダを参照)
  final TextEditingController _homeSearchCtrl = TextEditingController();
  String _homeQuery = '';
  bool _homeSearching = false;
  List<MediaItem> _homeSearchResults = const [];

  // 検索欄入力のたびに全フォルダ検索が動くのを防ぐ
  Timer? _homeSearchDebounce;

  // Home検索用、DBから引いたタグキャッシュ（itemId -> tagNames）
  Map<String, List<String>> _dbTagsByItemId = <String, List<String>>{};

  // フォルダ階層ナビ（ギャラリー内）
  final List<_FolderNavState> _dirStack = <_FolderNavState>[];

  bool get _canGoUp => _dirStack.isNotEmpty;
  

  Future<void> _enterFolder(MediaItem folderItem) async { 
    if (_folder == null) return;  

    // いま見ているフォルダ + その時のページを積む積む
    _dirStack.add(_FolderNavState(_folder!, _galleryPageIndex));

    // 入った先は従来通りページ1から
    await _loadFolder(FolderHandle(folderItem.id), saveAsLast: false, pageIndex: 0);
  }

  Future<void> _goUpFolder() async {
    if (_dirStack.isEmpty) return;
    final prev = _dirStack.removeLast();

    // 戻る時は「元のフォルダ」かつ「元のページ」に復帰
    await _loadFolder(prev.folder, saveAsLast: false, pageIndex: prev.pageIndex);
  }

  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  List<MediaItem> _filteredItems = const [];

  _SortMode _sortMode = _SortMode.name;

  // raw -> 表示名
  Map<String, String> _folderAliases = <String, String>{};

  // 全フォルダを監視、お気に入り表示用
  final Map<String, List<MediaItem>> _folderItemsCache = {};
  List<MediaItem> _favoriteItemsAll = const [];
  bool _loadingFavAll = false;

  // Home検索用（再帰＋ファイルのみ）
  final Map<String, List<MediaItem>> _folderItemsCacheRecursive = {};

  // ---- 複数選択モード ----
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

  // TabControllerのlistenerを二重登録しないため
  bool _tabListenerInstalled = false;

  //ID 変種生成
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

  // ---- サイドバー：作者タグ一覧 ----
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
    // 既に読み込んだフォルダ分だけで件数を作る（未ロード分は0になる）
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

    // タグ検索として検索結果ページへ（既存の検索グリッドを再利用）
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reloadArtistTagMasters();
    });
  }

  Future<void> _applySearchFilterDb() async {
    final q = _query.trim();

    if (q.isEmpty) {
      setState(() => _filteredItems = _items);
      return;
    }

    // 形式: key:value
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

    // folder 表示名を格納
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

    // favorites（お気に入り）
    final favList =
        prefs.getStringList(_PrefsKeys.favorites) ?? const <String>[];

    // tags（タグ）
    _tagsById = _decodeTags(prefs.getString(_PrefsKeys.tagsJson));

    // 表示設定
    final fitIndex = prefs.getInt(_PrefsKeys.fitMode);
    final two = prefs.getBool(_PrefsKeys.twoPage);

    // folders フォルダー
    List<String> folders =
        prefs.getStringList(_PrefsKeys.folders) ?? const <String>[];
    String? current = prefs.getString(_PrefsKeys.currentFolder);

    // もし、lastFolderRaw が残っていたら folders に入れる
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

    // folders に存在し無ければ先頭に入れる
    if (!folders.contains(libRaw)) {
      folders = <String>[libRaw, ...folders];
      await prefs.setStringList(_PrefsKeys.folders, folders);
    }

    // 保管庫に表示名も無ければ付与
    if (!aliases.containsKey(libRaw) || aliases[libRaw]!.trim().isEmpty) {
      aliases[libRaw] = '保管庫';
      await prefs.setString(_PrefsKeys.folderAliasesJson, jsonEncode(aliases));
    }

    // 実在チェック
    final existsFolders = <String>{};

    for (final p in folders) {
      // SAF, Treeuriはそのまま有効
      if (p.startsWith('content://')) {
        existsFolders.add(p);
        continue;
      }

      // Directory.exists で存在を判定
      try {
        final d = Directory(p);
        if (await d.exists()) existsFolders.add(p);
      } catch (_) {}
    }

    // current の整合性（無ければ保管庫をデフォルトとする）
    if (current == null || !existsFolders.contains(current)) {
      if (existsFolders.contains(libRaw)) {
        current = libRaw;
      } else {
        current = existsFolders.isNotEmpty ? existsFolders.first : null;
      }
    }

    //  実在しないフォルダが消えた場合は prefs も更新しておく
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

    // 選択中フォルダをロード
    await _loadFolder(FolderHandle(current), saveAsLast: false);
  }

  Future<void> _saveFolderTileMode(FolderTileMode m) async {
  setState(() => _folderTileMode = m);
  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt(_PrefsKeys.folderTileMode, m.index);
  }

  Future<Uint8List?> _getFolderPreviewBytes(MediaItem folderItem) {
    // スクロール中 / 初期描画中は生成しない
    //if (!_thumbsEnabled) return Future.value(null);

    final key = folderItem.id;

    // bytesを優先
    if (_folderPreviewCache.containsKey(key)) {
      return Future.value(_folderPreviewCacheGet(key));
    }

    final inflight = _folderPreviewInFlight[key];
    if (inflight != null) return inflight;

    Future<MediaItem?> pickCandidateInFolder(String folderRaw) async {
      const int pageLimit = 60;
      const int maxPages = 4; // 最大240件だけ見る（重くしない）

      MediaItem? firstImage;

      for (int p = 0; p < maxPages; p++) {
        final res = await widget.repo.listMediaPage(
          FolderHandle(folderRaw),
          offset: p * pageLimit,
          limit: pageLimit,
        );

        for (final it in res.items) {
          if (it.kind == MediaKind.pdf) return it; // PDF優先
          if (it.kind == MediaKind.image && firstImage == null) {
            firstImage = it;
          }
        }

        // 末尾まで来た
        if (res.items.length < pageLimit) break;
      }

      return firstImage;
    }

    final fut = () async {
      await _acquireFolderPreviewSlot(1); // フォルダ表紙は同時1に抑える
      try {
        // 1) まず直下から候補を探す（DBインデックス経由で速い）
        final cand = await pickCandidateInFolder(folderItem.id);
        if (cand != null) {
          final pair = await widget.repo.readThumbPair(cand, maxWidth: 240);
          _folderPreviewCachePut(key, pair.front);
          return pair.front;
        }

        // 2) 直下に無い場合：サブフォルダを少しだけ見る（1段だけ、最大3個）
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
  // Tags (SharedPreferences依存)

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

    // 空白を区切って、ANDを追加
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
      // #tag はタグのみ対象
      if (t.startsWith('#')) {
        final needle = t.substring(1);
        if (needle.isEmpty) return true;
        return tags.any((x) => x.contains(needle));
      }

      // 通常は ファイル名 or タグ
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
      // 全フォルダの items を cache へ（ロードされていない分だけ）
      for (final raw in _foldersRaw) {
        if (_folderItemsCache.containsKey(raw)) continue;
        try {
          // 全フォルダの “再帰ファイル一覧” を cache へ（未作成分だけ）
          for (final raw in _foldersRaw) {
            if (_folderItemsCacheRecursive.containsKey(raw)) continue;
            try {
              final list = await widget.repo.listMediaRecursiveFiles(FolderHandle(raw));
              // ★ 検索結果にフォルダが混じると困るので file only でOK
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
        } catch (_) {
          _folderItemsCache[raw] = const <MediaItem>[];
        }
      }

      final all = <MediaItem>[];
      for (final raw in _foldersRaw) {
        final list = _folderItemsCache[raw] ?? const <MediaItem>[];
        all.addAll(list);
      }

      // variants も含めてDBへ問い合わせる（IDがおかしくなっていた場合に備えて）
      final idSet = <String>{};
      for (final it in all) {
        idSet.addAll(_idVariants(it.id));
      }
      final ids = idSet.toList(growable: false);

      final rawMap = await widget.tagService.getTagNamesByItemIds(ids);

      // 取得結果も variants へ展開しておく
      final expanded = <String, List<String>>{};
      rawMap.forEach((k, v) {
        for (final vv in _idVariants(k)) {
          expanded[vv] = v;
        }
      });

      _dbTagsByItemId = expanded;

      final filtered = all
          .where((e) => _matchHomeQuery(e, q))
          .toList(growable: false);

      // 見やすさ優先で名前順（必要なら _sortMode を使う）
      final sorted = filtered.toList(growable: true)
        ..sort(
          (a, b) => a.displayName.toLowerCase().compareTo(
            b.displayName.toLowerCase(),
          ),
        );

      if (!mounted) return;
      setState(() {
        _homeSearching = false;
        _homeSearchResults = sorted.take(50).toList(growable: false); // 上限
      });
    } catch (e, st) {
      // なんで検索できないのかわからない
      // ここが見えないと原因が永遠に分からないのでログに出す
      print('[HOME SEARCH] error: $e\n$st');

      if (!mounted) return;
      setState(() {
        _homeSearching = false;
        _homeSearchResults = const [];
      });

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Home検索でエラー: $e')));
    }
  }

  Future<void> _organizeLibrary() async {
    try {
      final lib = await widget.repo.getAppLibraryFolder();
      final moved = await widget.tagService.organizeAppLibrary(
        libraryRoot: lib.raw,
      );

      if (!mounted) return;

      // 表示更新：今見てるフォルダが保管庫配下ならリロード
      if (_currentFolderRaw != null && _currentFolderRaw!.startsWith(lib.raw)) {
        await _loadFolder(FolderHandle(_currentFolderRaw!), saveAsLast: false);
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('保管庫整理: 移動 ${moved.length} 件')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('保管庫整理に失敗: $e')));
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
        // Homeの検索
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
                      hintText: 'タイトル / タグ / #tag で検索',
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
                      // Home検索は _homeQuery を更新して Home検索を走らせる
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
                  Text('件数: ${_homeSearchResults.length}（最大50件表示）'),
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
                              // サムネ（高さを入れる）
                              SizedBox(
                                height: 120, // ← ここを変えると大きさが変わる
                                child: _homeFavThumb(item),
                              ),

                              const SizedBox(width: 12),

                              // テキスト領域
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
                  const Text('登録フォルダがありません。「フォルダ追加」から追加してください。')
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
        child: Text('Homeの検索欄にキーワード（タイトル/タグ/#tag）を入力してください。'),
      );
    }

    if (_homeSearchResults.isEmpty) {
      return const Center(child: Text('該当するアイテムがありません'));
    }

    // Home検索結果は全フォルダだから、_items（現在フォルダ）を使わず
    // 検索結果リストをそのまま渡して詳細ページで前後移動できるようにする
    return _buildGridFromList(_homeSearchResults, showFolderLabel: true);
  }

  // --------------------
  // フォルダ表示名設定
  // --------------------
  String _basename(String raw) {
    String s = raw;
    //　アンドロイド対応がややこしいので１－４の順番通りにやる。
    // 1) SAFの content://... の場合は tree/document の次のsegs（セグメント）を取り出す
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
          s = encoded; // 例: primary%3ADocuments%2Fexperiment（androidの場合、実験フォルダを使う）
        }
      } catch (_) {
        // 失敗したら s=raw のままフォールバック
      }
    }

    // 2) 「primary%3A...」みたいにエンコード文字列だけ保存されているケースにも対応
    //    二重もあり得るので最大2回回す。
    for (int i = 0; i < 2; i++) {
      if (!s.contains('%')) break;
      try {
        s = Uri.decodeComponent(s);
      } catch (_) {
        break;
      }
    }

    // 3) "primary:" などボリューム名を落とす → 最後のパス要素だけにする
    final colon = s.indexOf(':');
    if (colon >= 0) s = s.substring(colon + 1);

    s = s.replaceAll('\\', '/');
    final slash = s.lastIndexOf('/');
    if (slash >= 0) s = s.substring(slash + 1);

    // 4) 空なら元の raw を返す
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
          title: const Text('フォルダ名を変更'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '表示名（タイトル）',
              hintText: '例：漫画 / 資料 / 仕事 など',
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
  // 永続化：表示設定
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
  // お気に入り（★）
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

    // フォルダが未登録なら登録
    if (!_foldersRaw.contains(folderRaw)) {
      final next = List<String>.from(_foldersRaw)..add(folderRaw);
      setState(() {
        _foldersRaw = next;
        _currentFolderRaw = folderRaw;
      });

      await _persistFolders();
    } else {
      // 登録済みなら current をフォルダーに合わせる
      if (_currentFolderRaw != folderRaw) {
        setState(() {
          _currentFolderRaw = folderRaw;
          _folder = FolderHandle(folderRaw);
        });
        await _persistFolders();
      }
    }

    // 対象フォルダをロード（キャッシュがあればそれを使う）
    if (_folderItemsCache.containsKey(folderRaw)) {
      setState(() {
        _items = _folderItemsCache[folderRaw] ?? const [];
        _folder = FolderHandle(folderRaw);
      });
    } else {
      await _loadFolder(FolderHandle(folderRaw), saveAsLast: false);
      // _loadFolder が _items を更新するときにキャッシュにも入れておく
      _folderItemsCache[folderRaw] = _items;
    }

    // 存在しているindex を探す（ない場合はSnackbarでテキストを返す）
    final idx = _items.indexWhere((e) => e.id == item.id);
    if (idx < 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ファイルが見つかりません（移動/削除された可能性）')),
      );
      return;
    }

    // 詳細ページへ一発で遷移する。
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

    // detailページでお気に入りが変わった場合、ホームの一覧のお気に入りも更新
    if (changed == true) {
      await _reloadFavorites();
      await _refreshAllFavoritesItems();
      if (_homeQuery.trim().isNotEmpty) {
        await _runHomeSearch(); // タグ変更をHome検索に反映
      }
    }
  }

  /// お気に入り一覧などで「このアイテムが属するフォルダの表示名」を返す
  String _folderLabelForItem(MediaItem item) {
    // お気に入りは「全フォルダ横断」なので、
    // 登録済みフォルダ（_foldersRaw）のどれに属するかを推定して表示する。
    final itemNorm = _normalizePath(item.id);

    String? bestMatchRaw;
    var bestLen = -1;

    for (final raw in _foldersRaw) {
      final folderNorm = _normalizePath(raw);

      // "C:\pics" と "C:\pics2" の誤一致を避けるため、最後の区切りまで見る。
      final ok = itemNorm == folderNorm || itemNorm.startsWith('$folderNorm\\');
      if (!ok) continue;

      if (folderNorm.length > bestLen) {
        bestLen = folderNorm.length;
        bestMatchRaw = raw;
      }
    }

    if (bestMatchRaw != null) {
      return _folderLabel(bestMatchRaw); // alias があれば alias、無ければ basename
    }

    // 登録外のフォルダから来た場合はすぐ上のフォルダ名を表示
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
  // フォルダー管理
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
        _filteredItems = res.items; // ←検索は「ページ内」でOKならこれでOK
        _loading = false;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) async {
       // 一覧を先に描画させてからサムネ開始
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
        SnackBar(content: Text('読み込み失敗: $e')),
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
        SnackBar(content: Text('ページ読み込み失敗: $e')),
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('追加しました: $count 件')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('追加に失敗: $e')));
    }
  }

  Future<void> _importToLibraryAndTag() async {
    try {
      final lib = await widget.repo.getAppLibraryFolder();
      final libRaw = lib.raw;

      // folders に保管庫がなければ入れる（念のため）
      if (!_foldersRaw.contains(libRaw)) {
        setState(() {
          _foldersRaw = <String>[libRaw, ..._foldersRaw];
        });
        await _persistFolders();
      }

      // 取り込み前のスナップショット
      final before = await widget.repo.listMedia(lib);
      final beforeIds = before.map((e) => e.id).toSet();

      // 取り込み実行
      final importedCount = await widget.repo.importIntoFolder(lib);
      if (!mounted) return;

      if (importedCount <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('取り込みはありませんでした')),
        );
        return;
      }

      // 取り込み後：差分抽出
      final after = await widget.repo.listMedia(lib);
      final newItems = after
          .where((e) => e.kind != MediaKind.folder && !beforeIds.contains(e.id))
          .toList(growable: false);

      // まず保管庫を開く（タグ画面の前に「保管庫が現在フォルダ」になるように）
      _dirStack.clear();
      setState(() {
        _currentFolderRaw = libRaw;
        _page = _MainPage.gallery; // 保管庫へ取り込んだらギャラリー表示に寄せる
      });
      await _persistFolders();

      // ギャラリーを保管庫で更新表示
      await _loadFolder(lib, saveAsLast: false);
      if (!mounted) return;

      // 差分が取れない場合でも、取り込み成功の通知は出す
      if (newItems.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保管庫へ取り込み: $importedCount 件（差分取得なし）')),
        );
        return;
      }

      // タグ付け画面を出す
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TagAssignAfterImportPage(
            items: newItems,
            tagService: widget.tagService,
          ),
        ),
      );

      if (!mounted) return;

      // タグ付け後：Home検索や件数表示にも反映させたいのでキャッシュ更新
      if (_homeQuery.trim().isNotEmpty) {
        await _runHomeSearch();
      }
      _rebuildTagCountCache();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保管庫へ取り込み: $importedCount 件（タグ付け対象: ${newItems.length} 件）')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('取り込み失敗: $e')),
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
      // 未キャッシュのフォルダだけ読み込む
      for (final raw in _foldersRaw) {
        if (_folderItemsCache.containsKey(raw)) continue;
        final items = await widget.repo.listMedia(FolderHandle(raw));
        _folderItemsCache[raw] = items;
      }

      // 全フォルダ分からお気に入りだけ抽出
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
        // ✅ folder は常に残しつつ、pdf を表示
        out = out.where((e) => e.kind == MediaKind.folder || e.kind == MediaKind.pdf);
      } else {
        // ✅ folder は常に残しつつ、image を表示
        out = out.where((e) => e.kind == MediaKind.folder || e.kind == MediaKind.image);
      }
    }

    final qRaw = _query.trim().toLowerCase();
    if (qRaw.isNotEmpty) {
      // 空白区切りで複数条件:
      // - "#tag" : タグ一致（部分一致） 　　　　　#のあとに一致するものがあるのか
      // - "word" : ファイル名 or タグに部分一致　#のあとでも普通の文字でもとにかくあてはまるものがあるのか
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

  /// 「タグなし」タブ用: フォルダは除外し、タグが1つも付いていない画像/PDFのみ表示
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
            title: Text('アーティストタグ一覧'),
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
            title: Text('保管庫を整理（作者/シリーズ）'),
          ),
        ),
        const PopupMenuItem(
          value: _GalleryMenuAction.exportPdf,
          child: ListTile(
            leading: Icon(Icons.picture_as_pdf_outlined),
            title: Text('このフォルダの画像をPDFにまとめる'),
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
        title: const Text('PDFを生成中...'),
        content: StatefulBuilder(
          builder: (context, setD) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: total == 0 ? null : done / total),
              const SizedBox(height: 12),
              Text('$done / $total'),
              const SizedBox(height: 8),
              const Text('保存先フォルダを選択後、生成を開始します'),
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
          SnackBar(content: Text('PDF保存完了: ${created.name}')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('PDF出力に失敗: $e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }
  Future<void> _showFolderTileModeDialog() async {
    final mode = await showDialog<FolderTileMode>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('フォルダ表示'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, FolderTileMode.labelOnly),
            child: const Text('フォルダ＋名前（軽量）'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, FolderTileMode.preview),
            child: const Text('表紙プレビュー（重い）'),
          ),
        ],
      ),
    );

    if (mode == null) return;
    _saveFolderTileMode(mode); // ←あなたが持ってる既存関数を呼ぶ想定
  }

  // --- UI: responsive sidebar (Windows/desktop friendly) ---
  static const double _kSidebarWidth = 340;

  bool _isWideLayout(BuildContext context) =>
      MediaQuery.of(context).size.width >= 980;

  void _closeSidebar() {
    // Drawer表示時のみ閉じる（デスクトップの常設サイドバーでは pop しない）
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
          Text('Media Viewer', style: Theme.of(context).textTheme.titleLarge),
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

                // フォルダ未選択ならホームで案内（またはフォルダ追加）
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
            _sidebarSectionLabel('作者タグ'),
            if (_loadingArtistTags)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: LinearProgressIndicator(),
              )
            else
              ExpansionTile(
                leading: const Icon(Icons.person_outline),
                title: const Text('作者（カテゴリ）'),
                children: [
                  if (_artistTagMasters.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      child: Text('作者タグがまだありません'),
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
                  labelText: 'Fitモード',
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
                        child: Text('全体表示(Contain)'),
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
              title: const Text('見開き (ON/OFF)'),
              value: _twoPage,
              onChanged: (v) async {
                setState(() => _twoPage = v);
                await _saveTwoPage(v);
              },
            ),
            const Divider(),
            _sidebarSectionLabel('フォルダ'),

            // 追加ボタン
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
                  '※登録フォルダと選択中フォルダは再起動後も復元します（存在する場合）。',
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
    // ホーム画面
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

    // 検索結果（Home検索をギャラリー表示する。）
    if (_page == _MainPage.search) {
      return Scaffold(
        drawer: _isWideLayout(context) ? null : _buildSidebar(),
        appBar: AppBar(
          title: const Text('検索結果'),
          actions: _selectMode
              ? [
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
                    tooltip: '選択に一括タグ付与',
                    onPressed: () {
                      final targets = _selectedFrom(_homeSearchResults);
                      _bulkAddTagToItems(targets);
                    },
                    icon: const Icon(Icons.label_outline),
                  ),
                  IconButton(
                    tooltip: '選択を保管庫に取り込む（重複はスキップ）',
                   onPressed: () {
                    // ここでその場でタブ番号を取る
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

    // ギャラリー画面
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
                      tooltip: '上のフォルダへ',
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
                        tooltip: '選択に一括タグ付与',
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
                        tooltip: '選択を保管庫に取り込む（重複はスキップ）',
                        onPressed: () {
                          // ここでその場でタブ番号を取る
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
                // 検索(約56) + ソート(約40) + TabBar(約48) + 余白
                //　= 160前後は必要
                preferredSize: const Size.fromHeight(160),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ---- 検索バー ----
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      child: SizedBox(
                        height: 44, // 高さを決定
                        child: TextField(
                          controller: _searchCtrl,
                          decoration: InputDecoration(
                            prefixIcon: const Icon(Icons.search),
                            hintText: 'タイトルで検索',
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
                                      _applySearchFilterDb();
                                    },
                                  ),
                          ),
                          onChanged: (v) => setState(() => _query = v),
                        ),
                      ),
                    ),

                    // ---- ソート行 ----
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: SizedBox(
                        height: 36,
                        child: Row(
                          children: [
                            const Text('ソート: '),
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

                    // ---- タブ ----
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
                ? const Center(child: Text('画像/PDFがありません'))
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
        return '作者';
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
                  hintText: '例: #夏 / artist:xxx の「xxx」など',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => Navigator.of(ctx).pop(true),
              ),
              const SizedBox(height: 8),
              const Text(
                '※空白を含むタグは不可（検索の分解が崩れるため）',
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

    // 進捗ダイアログ
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

      // Home検索用のタグキャッシュを更新（対象IDだけ取り直し）
      final ids = targets.map((e) => e.id).toList(growable: false);
      final got = await widget.tagService.getTagNamesByItemIds(ids);
      if (!mounted) return;
      setState(() {
        for (final e in got.entries) {
          _dbTagsByItemId[e.key] = e.value;
        }
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('「$name」を${targets.length}件に付与しました')),
      );
    } finally {
      // 進捗ダイアログを閉じる
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
  }

  Future<void> _importSelectedToLibrary(List<MediaItem> targets) async {
    if (targets.isEmpty) return;

    // 取り込み先（保管庫）
    final lib = await widget.repo.getAppLibraryFolder();

    // 取り込み前スナップショット（新規分を特定してタグ付け画面にも渡せる）
    final before = await widget.repo.listMedia(lib);
    final beforeIds = before.map((e) => e.id).toSet();

    // 同名があればスキップする（軽量重複回避）
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

    // 取り込み後差分＝今回新規で増えたファイル
    final after = await widget.repo.listMedia(lib);
    final newItems = after
        .where((e) => e.kind != MediaKind.folder && !beforeIds.contains(e.id))
        .toList(growable: false);

    if (!mounted) return;

    // 取り込み直後タグ付け（あなたが前に入れている tag_assign_after_import.dart を活用）
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

    // 選択解除 + 表示更新
    _exitSelectMode();
    setState(() {});
  }

  Widget _buildGrid(List<MediaItem> items, {bool showFolderLabel = false}) {
    if (items.isEmpty) {
      return const Center(child: Text('該当するアイテムがありません'));
    }

     return Column(
      children: [
        // ★ 一番上にページャ
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

            // folder除外でDetailページへ
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
    // ① 軽量モード：プレビューを一切呼ばない
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
      
            // ✅ selected overlay（ここで readThumbPair を呼ばない）
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
          // NOTE: _thumbsEnabled が false の間は FutureBuilder 自体を作らない（= サムネ生成を開始しない）
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

          // 右上：PDFバッジ + ★
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
          // ここで失敗を出力
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
