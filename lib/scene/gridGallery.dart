import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:io' show Platform;
import 'dart:typed_data';


import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/folder.dart';
import '../models/mediaItem.dart';
import '../repository/mediaRepository.dart';
import '../database/tag_service.dart';
import '../models/tag.dart';

import 'detailImage.dart';

enum _SortMode { name, updatedAt, addedAt }

enum _MainPage { home, gallery, search }

class _PrefsKeys {
  // 旧キー（移行用に残す）
  static const String lastFolderRaw = 'prefs.lastFolderRaw';

  // ★ 複数フォルダ管理
  static const String folders = 'prefs.folders'; // List<String>（raw path）
  static const String currentFolder = 'prefs.currentFolder'; // String（raw path）

  static const String fitMode =
      'prefs.readerFitMode'; // int (ReaderFitMode.index)
  static const String twoPage = 'prefs.readerTwoPage'; // bool

  static const String favorites = 'prefs.favorites'; // List<String>

  static const String folderAliasesJson = 'prefs.folderAliasesJson';

  /// json map: { "<MediaItem.id>": ["tag1","tag2", ...] }
  static const String tagsJson = 'prefs.tagsJson';
}

class GalleryGridPage extends StatefulWidget {
  final MediaRepository repo;
  final TagService tagService;
  
  const GalleryGridPage({super.key, required this.repo, required this.tagService});

  @override
  State<GalleryGridPage> createState() => _GalleryGridPageState();
}

class _GalleryGridPageState extends State<GalleryGridPage> {
  FolderHandle? _folder;
  List<MediaItem> _items = const [];
  bool _loading = false;

  String _parentDirOfFullPath(String fullPath) {
    // Windows: "C:\a\b\c.jpg" / "C:/a/b/c.jpg" どちらも対応
    final p = fullPath.replaceAll('/', '\\');
    final idx = p.lastIndexOf('\\');
    if (idx <= 0) return p; // 念のため
    return p.substring(0, idx);
  }

  Set<String> _favorites = <String>{};

  // tags
  Map<String, List<String>> _tagsById = <String, List<String>>{};

  _MainPage _page = _MainPage.home; // ★起動時はホーム

  // 複数フォルダ
  List<String> _foldersRaw = const []; // 登録済みフォルダ一覧（raw）
  String? _currentFolderRaw; // 現在選択（raw）

  // ---- 表示設定（永続化）----
  ReaderFitMode _fitMode = ReaderFitMode.vertical;
  bool _twoPage = false;

  
  // --- ホーム画面検索 (すべてのフォルダを参照) ---
  final TextEditingController _homeSearchCtrl = TextEditingController();
  String _homeQuery = '';
  bool _homeSearching = false;
  List<MediaItem> _homeSearchResults = const [];

  // 入力のたびに重い全フォルダ検索が走るのを防ぐ
  Timer? _homeSearchDebounce;

  // Home検索用：DBから引いたタグキャッシュ（itemId -> tagNames）
  Map<String, List<String>> _dbTagsByItemId = <String, List<String>>{};



  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  List<MediaItem> _filteredItems = const [];

  _SortMode _sortMode = _SortMode.name;

  // raw -> 表示名
  Map<String, String> _folderAliases = <String, String>{};

  // 全フォルダ横断★表示用
  final Map<String, List<MediaItem>> _folderItemsCache = {};
  List<MediaItem> _favoriteItemsAll = const [];
  bool _loadingFavAll = false;

  // TabController listenerを二重登録しないため
  bool _tabListenerInstalled = false;


  //ID 変種生成
  Set<String> _idVariants(String id) {
  final s = <String>{id};

  // slash 揺れ（Windowsで頻出）
  s.add(id.replaceAll('/', '\\'));
  s.add(id.replaceAll('\\', '/'));

  // Windowsはケース無視が多いので lower も混ぜる（DB側がどっちで保存されていても拾える）
  final lower = id.toLowerCase();
  s.add(lower);
  s.add(lower.replaceAll('/', '\\'));
  s.add(lower.replaceAll('\\', '/'));

  return s;
}

  
  @override
  void initState() {
    super.initState();
    _loadPrefsAndAutoOpenFolder();
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
        // folderRaw は現在表示中フォルダの値に合わせてください
        // _currentFolderRaw などがあるならそれを使う
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

  // fallback: ファイル名部分一致
  final lower = q.toLowerCase();
  final filtered = _items
      .where((it) => it.displayName.toLowerCase().contains(lower))
      .toList();

  setState(() => _filteredItems = filtered);
}


  Future<void> _loadPrefsAndAutoOpenFolder() async {
    final prefs = await SharedPreferences.getInstance();

    // folder aliases restore
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

    // favorites
    final favList =
        prefs.getStringList(_PrefsKeys.favorites) ?? const <String>[];

    // tags
    _tagsById = _decodeTags(prefs.getString(_PrefsKeys.tagsJson));

    // view settings
    final fitIndex = prefs.getInt(_PrefsKeys.fitMode);
    final two = prefs.getBool(_PrefsKeys.twoPage);

    // ★ folders restore
    List<String> folders =
        prefs.getStringList(_PrefsKeys.folders) ?? const <String>[];
    String? current = prefs.getString(_PrefsKeys.currentFolder);

    // --- 旧仕様からの移行（lastFolderRaw が残っていたら folders に入れる）---
    if (folders.isEmpty) {
      final legacy = prefs.getString(_PrefsKeys.lastFolderRaw);
      if (legacy != null && legacy.isNotEmpty) {
        if (Platform.isWindows) {
          folders = <String>[legacy];
          current = legacy;
          await prefs.setStringList(_PrefsKeys.folders, folders);
          await prefs.setString(_PrefsKeys.currentFolder, legacy);
        } else {
          // Android: 旧仕様の「実パス」は無効なので捨てる
          await prefs.remove(_PrefsKeys.lastFolderRaw);
        }
      }
    }

    // --- 実在チェック（消えているフォルダを除外）---
    final existsFolders = <String>{};

    for (final p in folders) {
      // ★ _foldersRaw ではなく prefs から読んだ folders
      if (Platform.isWindows) {
        try {
          final d = Directory(p);
          if (await d.exists()) existsFolders.add(p);
        } catch (_) {}
      } else {
        // Android: SAFの treeUri（content://...）だけ有効
        if (p.startsWith('content://')) {
          existsFolders.add(p);
        }
      }
    }

    // current の整合性
    if (current == null || !existsFolders.contains(current)) {
      current = existsFolders.isNotEmpty ? existsFolders.first : null;
    }

    // ★ 実在しないフォルダが消えた場合は prefs も更新しておく（重要）
    await prefs.setStringList(_PrefsKeys.folders, existsFolders.toList());

    if (current != null) {
      await prefs.setString(_PrefsKeys.currentFolder, current);
    } else {
      await prefs.remove(_PrefsKeys.currentFolder);
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

    // 選択中フォルダをロード（保存処理はここでは不要）
    await _loadFolder(FolderHandle(current), saveAsLast: false);
  }

  // ----------------
  // Tags (SharedPreferences)

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

    // 空白区切りAND
    final tokens = q.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
    final name = item.displayName.toLowerCase();

    final tags = (_dbTagsByItemId[item.id] ??
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
      // 全フォルダの items を cache へ（未ロード分だけ）
      for (final raw in _foldersRaw) {
        if (_folderItemsCache.containsKey(raw)) continue;
        try {
          final list = await widget.repo.listMedia(FolderHandle(raw));
          _folderItemsCache[raw] = list;
        } catch (_) {
          _folderItemsCache[raw] = const <MediaItem>[];
        }
      }

      final all = <MediaItem>[];
      for (final raw in _foldersRaw) {
        final list = _folderItemsCache[raw] ?? const <MediaItem>[];
        all.addAll(list);
      }

      // ★ IDの揺れに強いように variants も含めてDBへ問い合わせる
      final idSet = <String>{};
      for (final it in all) {
        idSet.addAll(_idVariants(it.id));
      }
      final ids = idSet.toList(growable: false);

      final rawMap = await widget.tagService.getTagNamesByItemIds(ids);

      // ★ 取得結果も variants へ展開しておく（lookup時に確実に当てる）
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


      // 見やすさ優先で名前順（必要なら _sortMode を使ってもOK）
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
      // ここが見えないと原因が永遠に分からないのでログに出す
      // ignore: avoid_print
      print('[HOME SEARCH] error: $e\n$st');
    
      if (!mounted) return;
      setState(() {
        _homeSearching = false;
        _homeSearchResults = const [];
      });
    
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Home検索でエラー: $e')),
      );
    }

  }

  Widget _homeFavThumb(MediaItem item) {
    return AspectRatio(
      aspectRatio: 3 / 4, // ★ 縦長（漫画・PDF向け）
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
              fit: BoxFit.cover, // ★縦横比を保ったまま枠いっぱい
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
        // --- Home: Global search ---
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
                    // ★ Home検索は _homeQuery を更新して Home検索を走らせる
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
                              // ★ サムネ（高さを明示）
                              SizedBox(
                                height: 120, // ← ここを変えると「大きさ」が変わる
                                child: _homeFavThumb(item),
                              ),

                              const SizedBox(width: 12),

                              // ★ テキスト領域
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
      return const Center(child: Text('Homeの検索欄にキーワード（タイトル/タグ/#tag）を入力してください。'));
    }

    if (_homeSearchResults.isEmpty) {
      return const Center(child: Text('該当するアイテムがありません'));
    }

    // ★ Home検索結果は「全フォルダ」なので、_items（現在フォルダ）を使わず
    // 検索結果リストをそのまま渡して詳細で前後移動できるようにする
    return _buildGridFromList(_homeSearchResults, showFolderLabel: true);
  }


  // --------------------
  // フォルダ表示名設定
  // --------------------
  String _basename(String raw) {
    String s = raw;

    // 1) SAFの content://... の場合は tree/document の次のセグメントを取り出す
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
          s = encoded; // 例: primary%3ADocuments%2Fexperiment
        }
      } catch (_) {
        // 失敗したら s=raw のままフォールバック
      }
    }

    // 2) 「primary%3A...」みたいにエンコード文字列だけ保存されているケースにも対応
    //    二重エンコードもあり得るので最大2回 decode
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

    // 1) フォルダが未登録なら登録（ユーザー体験的にここで登録するのが自然）
    if (!_foldersRaw.contains(folderRaw)) {
      final next = List<String>.from(_foldersRaw)..add(folderRaw);
      setState(() {
        _foldersRaw = next;
        _currentFolderRaw = folderRaw;
      });

      await _persistFolders();
    } else {
      // 登録済みなら current を合わせる
      if (_currentFolderRaw != folderRaw) {
        setState(() {
          _currentFolderRaw = folderRaw;
          _folder = FolderHandle(folderRaw);
        });
        await _persistFolders();
      }
    }

    // 2) 対象フォルダをロード（キャッシュがあればそれを使う）
    if (_folderItemsCache.containsKey(folderRaw)) {
      setState(() {
        _items = _folderItemsCache[folderRaw] ?? const [];
        _folder = FolderHandle(folderRaw);
      });
    } else {
      await _loadFolder(FolderHandle(folderRaw), saveAsLast: false);
      // _loadFolder が _items を更新する前提。キャッシュにも入れておく
      _folderItemsCache[folderRaw] = _items;
    }

    // 3) index を探す
    final idx = _items.indexWhere((e) => e.id == item.id);
    if (idx < 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ファイルが見つかりません（移動/削除された可能性）')),
      );
      return;
    }

    // 4) 詳細へ一発で遷移
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

    // detailで★が変わった場合、ホームの一覧も更新
    if (changed == true) {
      await _reloadFavorites();
      await _refreshAllFavoritesItems();
      if (_homeQuery.trim().isNotEmpty) {
        await _runHomeSearch(); // ★タグ変更をHome検索に反映
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

      // "C:\pics" と "C:\pics2" の誤一致を避けるため、区切りまで見る
      final ok = itemNorm == folderNorm || itemNorm.startsWith('$folderNorm\\');
      if (!ok) continue;

      if (folderNorm.length > bestLen) {
        bestLen = folderNorm.length;
        bestMatchRaw = raw; // 元のraw（エイリアス用）
      }
    }

    if (bestMatchRaw != null) {
      return _folderLabel(bestMatchRaw); // alias があれば alias、無ければ basename
    }

    // 登録外のフォルダから来た場合は「直上フォルダ名」を表示
    final parentRaw = _parentDirOfFullPath(item.id);
    return _basename(parentRaw);
  }

  String _normalizePath(String p) {
    // Windows: 大文字小文字・スラッシュ揺れを吸収
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
  }) async {
    setState(() {
      _folder = folder;
      _loading = true;
      _items = const [];
    });

    if (saveAsLast) {
      await _saveLastFolder(folder);
    }

    final items = await widget.repo.listMedia(folder);
    // ignore: avoid_print
    print('[UI] loaded items=${items.length} folder=${folder.raw}');
    if (!mounted) return;
    setState(() {
      _items = items;
     _filteredItems = items; // ★追加
      _loading = false;
    });
    _applySearchFilterDb(); // ★検索中なら反映
    _folderItemsCache[folder.raw] = _items;
    await _refreshAllFavoritesItems();
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

      // 全フォルダ分から★だけ抽出
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
        out = out.where((e) => e.kind == MediaKind.pdf);
      } else {
        out = out.where((e) => e.kind != MediaKind.pdf);
      }
    }

    final qRaw = _query.trim().toLowerCase();
    if (qRaw.isNotEmpty) {
      // 空白区切りで複数条件:
      // - "#tag" : タグ一致（部分一致）
      // - "word" : ファイル名 or タグに部分一致
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

  Drawer _buildSidebar() {
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            ListTile(
              leading: const Icon(Icons.home_outlined),
              title: const Text('ホーム'),
              selected: _page == _MainPage.home,
              onTap: () {
                Navigator.pop(context);
                setState(() => _page = _MainPage.home);
              },
            ),
            ListTile(
              leading: const Icon(Icons.grid_view),
              title: const Text('ギャラリー'),
              selected: _page == _MainPage.gallery,
              onTap: () async {
                Navigator.pop(context);

                // フォルダ未選択ならホームで案内（またはフォルダ追加）
                if (_currentFolderRaw == null) {
                  setState(() => _page = _MainPage.home);
                  return;
                }

                setState(() => _page = _MainPage.gallery);
              },
            ),
            const Divider(),

            const ListTile(title: Text('表示設定'), dense: true),
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
            const ListTile(title: Text('フォルダ'), dense: true),

            // 追加ボタン
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('フォルダを追加'),
              onTap: () async {
                Navigator.pop(context);
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
                          Navigator.pop(context);
                          await _renameFolder(raw);
                        },
                      ),
                      IconButton(
                        tooltip: 'このフォルダを削除',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          Navigator.pop(context);
                          await _removeFolder(raw);
                        },
                      ),
                    ],
                  ),

                  onTap: () async {
                    Navigator.pop(context);
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
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // ★ ホーム画面
    if (_page == _MainPage.home) {
      return Scaffold(
        drawer: _buildSidebar(),
        appBar: AppBar(
          title: const Text('ホーム'),
          actions: [
            IconButton(
              tooltip: 'フォルダ追加',
              onPressed: _addFolder,
              icon: const Icon(Icons.create_new_folder_outlined),
            ),
            IconButton(
              tooltip: 'お気に入り更新',
              onPressed: _refreshAllFavoritesItems,
              icon: const Icon(Icons.star),
            ),
            IconButton(
              tooltip: '検索結果(ギャラリー)',
              onPressed: () => setState(() => _page = _MainPage.search),
              icon: const Icon(Icons.grid_view),
            ),
          ],
        ),
        body: _buildHomeBody(),
      );
    }

    // ★ 検索結果（Home検索のギャラリー表示）
    if (_page == _MainPage.search) {
      return Scaffold(
        drawer: _buildSidebar(),
        appBar: AppBar(
          title: const Text('検索結果'),
          actions: [
            IconButton(
              tooltip: 'ホームへ',
              onPressed: () => setState(() => _page = _MainPage.home),
              icon: const Icon(Icons.home_outlined),
            ),
            IconButton(
              tooltip: 'ギャラリーへ',
              onPressed: () => setState(() => _page = _MainPage.gallery),
              icon: const Icon(Icons.photo_library_outlined),
            ),
          ],
        ),
        body: _buildHomeSearchGalleryBody(),
      );
    }


    // ★ ギャラリー画面（あなたの既存）
    return DefaultTabController(
      length: 4,
      child: Builder(
        builder: (context) {
          final TabController tc = DefaultTabController.of(context);
          if (!_tabListenerInstalled) {
            _tabListenerInstalled = true;
            tc.addListener(() {
              if (!tc.indexIsChanging && tc.index == 3) {
                _refreshAllFavoritesItems();
              }
            });
          }

          return Scaffold(
            drawer: _buildSidebar(),
            appBar: AppBar(
              title: Text(
                _currentFolderRaw == null
                    ? '一覧表示'
                    : '一覧表示: ${_folderLabel(_currentFolderRaw!)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              actions: [
                IconButton(
                  tooltip: 'フォルダ追加',
                  onPressed: _addFolder,
                  icon: const Icon(Icons.create_new_folder_outlined),
                ),
                IconButton(
                  tooltip: 'ホームへ',
                  onPressed: () => setState(() => _page = _MainPage.home),
                  icon: const Icon(Icons.home_outlined),
                ),
              ],
              bottom: PreferredSize(
                // 検索(約56) + ソート(約40) + TabBar(約48) + 余白 = 160前後は必要
                preferredSize: const Size.fromHeight(160),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ---- 検索バー ----
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      child: SizedBox(
                        height: 44, // 高さを固定して「つぶれ」を防止
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
                            if (_loading)
                              const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),

                    // ---- タブ ----
                    const TabBar(
                      isScrollable: true, // 画面幅が広い時の “間延び” も防げる
                      tabs: [
                        Tab(text: 'すべて'),
                        Tab(text: '画像'),
                        Tab(text: 'PDF'),
                        Tab(text: 'お気に入り'),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            body: _folder == null
                ? Center(
                    child: ElevatedButton(
                      // ※ここは「フォルダ追加」に寄せたほうがUX良い
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
                      _buildGrid(_applyFilter(_items, pdfOnly: false)),
                      _buildGrid(_applyFilter(_items, pdfOnly: true)),
                      _loadingFavAll
                          ? const Center(child: CircularProgressIndicator())
                          : _buildGrid(
                              _favoriteItemsAll,
                              showFolderLabel: true,
                            ),
                    ],
                  ),
          );
        },
      ),
    );
  }

  Widget _buildGrid(List<MediaItem> items, {bool showFolderLabel = false}) {
    if (items.isEmpty) {
      return const Center(child: Text('該当するアイテムがありません'));
    }

    return GridView.builder(
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

        return InkWell(
          onTap: () async {
            // 表示自体は「全アイテム基準」で前後移動できるようにする
            final index = _items.indexOf(item);

            final changed = await Navigator.push<bool>(
              context,
              MaterialPageRoute(
                builder: (_) => ImageDetailPage(
                  repo: widget.repo,
                  tagService: widget.tagService,
                  items: _items,
                  initialIndex: index < 0 ? 0 : index,
                  initialPdfPage: 1,
                ),
              ),
            );

            // 詳細側で★が変わった場合、同期
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
          ),
        );
      },
    );
  }

  Widget _buildGridFromList(List<MediaItem> items, {bool showFolderLabel = false}) {
    if (items.isEmpty) {
      return const Center(child: Text('該当するアイテムがありません'));
    }
  
    return GridView.builder(
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
  
        return InkWell(
          onTap: () async {
            final changed = await Navigator.push<bool>(
              context,
              MaterialPageRoute(
                builder: (_) => ImageDetailPage(
                  repo: widget.repo,
                  tagService: widget.tagService,
                  items: items,          // ★ここが重要：検索結果リスト基準
                  initialIndex: i,
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

  const _ThumbTile({
    required this.repo,
    required this.item,
    this.subtitle,
    required this.isFavorite,
    required this.onToggleFavorite,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ThumbPair>(
      future: repo.readThumbPair(item, maxWidth: 360),
      builder: (context, snap) {
        if (!snap.hasData) return const _TileShell(loading: true);
        final bytes = snap.data!.front;

        return Material(
          elevation: 2,
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              Positioned(
                top: 6,
                left: 6,
                child: _FavButton(
                  isFavorite: isFavorite,
                  onPressed: onToggleFavorite,
                ),
              ),
              Positioned.fill(child: _ThumbImage(bytes: bytes)),
              Positioned(
                left: 8,
                right: 8,
                bottom: 8,
                child: _TitleChip(title: item.displayName, subtitle: subtitle),
              ),
              if (item.kind == MediaKind.pdf)
                const Positioned(top: 8, right: 8, child: _PdfBadge()),
            ],
          ),
        );
      },
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
          // ここで「デコード失敗」が見える
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
