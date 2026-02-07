import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/folder.dart';
import '../models/mediaItem.dart';
import '../repository/mediaRepository.dart';
import 'detailImage.dart';

enum _SortMode { name, updatedAt, addedAt }

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
}

class GalleryGridPage extends StatefulWidget {
  final MediaRepository repo;
  const GalleryGridPage({super.key, required this.repo});

  @override
  State<GalleryGridPage> createState() => _GalleryGridPageState();
}

class _GalleryGridPageState extends State<GalleryGridPage> {
  FolderHandle? _folder;
  List<MediaItem> _items = const [];
  bool _loading = false;

  Set<String> _favorites = <String>{};

  // 複数フォルダ
  List<String> _foldersRaw = const []; // 登録済みフォルダ一覧（raw）
  String? _currentFolderRaw; // 現在選択（raw）

  // ---- 表示設定（永続化）----
  ReaderFitMode _fitMode = ReaderFitMode.vertical;
  bool _twoPage = false;

  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  _SortMode _sortMode = _SortMode.name;

  @override
  void initState() {
    super.initState();
    _loadPrefsAndAutoOpenFolder();
  }

  Future<void> _loadPrefsAndAutoOpenFolder() async {
    final prefs = await SharedPreferences.getInstance();

    // favorites
    final favList =
        prefs.getStringList(_PrefsKeys.favorites) ?? const <String>[];

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
        folders = <String>[legacy];
        current = legacy;
        await prefs.setStringList(_PrefsKeys.folders, folders);
        await prefs.setString(_PrefsKeys.currentFolder, legacy);
      }
    }

    // --- 実在チェック（消えているフォルダを除外）---
    final existsFolders = <String>[];
    for (final p in folders) {
      if (p.isEmpty) continue;
      try {
        final d = Directory(p);
        if (await d.exists()) existsFolders.add(p);
      } catch (_) {}
    }

    // current の整合性
    if (current == null || !existsFolders.contains(current)) {
      current = existsFolders.isNotEmpty ? existsFolders.first : null;
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
    });

    if (current == null) return;

    // 選択中フォルダをロード（保存処理はここでは不要）
    await _loadFolder(FolderHandle(current), saveAsLast: false);
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
  }

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
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
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

    await _persistFolders();

    if (nextCurrent == null) return;
    await _loadFolder(FolderHandle(nextCurrent), saveAsLast: false);
  }

  Future<void> _pickFolderAndLoad() async {
    final folder = await widget.repo.pickFolder();
    if (folder == null) return;
    await _loadFolder(folder, saveAsLast: true);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
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

    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      out = out.where((e) => e.displayName.toLowerCase().contains(q));
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
                    raw,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  selected: raw == _currentFolderRaw,
                  trailing: IconButton(
                    tooltip: 'このフォルダを削除',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      // Drawerを閉じずに消すと見た目が崩れやすいので一旦閉じる
                      Navigator.pop(context);
                      await _removeFolder(raw);
                    },
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
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        drawer: _buildSidebar(),
        appBar: AppBar(
          title: Text(
            _currentFolderRaw == null ? '一覧表示' : '一覧表示: $_currentFolderRaw',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),

          actions: [
            IconButton(
              tooltip: 'フォルダ追加',
              onPressed: _addFolder,
              icon: const Icon(Icons.create_new_folder_outlined),
            ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(112),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _searchCtrl,
                          textInputAction: TextInputAction.search,
                          decoration: InputDecoration(
                            hintText: 'タイトルで検索',
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: _query.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: 'クリア',
                                    icon: const Icon(Icons.clear),
                                    onPressed: () {
                                      _searchCtrl.clear();
                                      setState(() => _query = '');
                                    },
                                  ),
                            border: const OutlineInputBorder(),
                            isDense: true,
                            filled: true,
                          ),
                          onChanged: (v) => setState(() => _query = v),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 140,
                        child: InputDecorator(
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<_SortMode>(
                              value: _sortMode,
                              isDense: true,
                              icon: const Icon(Icons.sort),
                              items: const [
                                DropdownMenuItem(
                                  value: _SortMode.name,
                                  child: Text('名前順'),
                                ),
                                DropdownMenuItem(
                                  value: _SortMode.updatedAt,
                                  child: Text('更新日時'),
                                ),
                                DropdownMenuItem(
                                  value: _SortMode.addedAt,
                                  child: Text('追加日時'),
                                ),
                              ],
                              onChanged: (v) {
                                if (v == null) return;
                                setState(() => _sortMode = v);
                              },
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const TabBar(
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
                  onPressed: _pickFolderAndLoad,
                  child: const Text('フォルダ選択'),
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
                  _buildGrid(
                    _applyFilter(
                      _items
                          .where((e) => _favorites.contains(e.id))
                          .toList(growable: false),
                      pdfOnly: null,
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildGrid(List<MediaItem> items) {
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
                  items: _items,
                  initialIndex: index < 0 ? 0 : index,
                  initialPdfPage: 1,
                ),
              ),
            );

            // 詳細側で★が変わった場合、同期
            if (changed == true) {
              await _reloadFavorites();
            }
          },
          child: _ThumbTile(
            repo: widget.repo,
            item: item,
            isFavorite: isFav,
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

  final bool isFavorite;
  final VoidCallback onToggleFavorite;

  const _ThumbTile({
    required this.repo,
    required this.item,
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
                child: _TitleChip(text: item.displayName),
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
  final String text;
  const _TitleChip({required this.text});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.65),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Text(
          text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontSize: 12),
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
