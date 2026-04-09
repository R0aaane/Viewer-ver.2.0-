import 'dart:typed_data';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/folder.dart';
import '../models/mediaItem.dart';
import '../repository/mediaRepository.dart';

import '../database/tag_service.dart';
import '../models/tag.dart';
import '../services/item_name_service.dart';
import 'rename_item_dialog.dart';

enum ReaderFitMode { vertical, horizontal, contain }

enum _DetailMenuAction { delete }

class _PrefsKeys {
  static const String lastFolderRaw = 'prefs.lastFolderRaw';
  static const String fitMode = 'prefs.readerFitMode';
  static const String twoPage = 'prefs.readerTwoPage';

  static const String favorites = 'prefs.favorites';
}

class ImageDetailPage extends StatefulWidget {
  final MediaRepository repo;
  final TagService tagService;
  final List<MediaItem> items;
  final int initialIndex;
  final int? initialPdfPage;

  const ImageDetailPage({
    super.key,
    required this.repo,
    required this.tagService,
    required this.items,
    required this.initialIndex,
    this.initialPdfPage,
  });

  @override
  State<ImageDetailPage> createState() => _ImageDetailPageState();
}

class _ImageDetailPageState extends State<ImageDetailPage>
    with SingleTickerProviderStateMixin {
  FolderHandle? _folder;

  late List<MediaItem> _items;
  late int _index;

  late final TabController _tab;

  int _page = 1;
  int _totalPages = 1;

  bool _twoPage = false;
  bool _fullscreen = false;
  bool _inReader = true;

  bool _isFavorite = false;
  bool _favChanged = false;
  bool _itemChanged = false;

  // tag・医ち繧ｰ・・
  List<TagWithId> _tags = const [];
  bool _tagsChanged = false;

  //縲繝輔か繝ｫ繝繧・ヵ繧｡繧､繝ｫ繧貞炎髯､
  String? _libraryRootRaw;
  bool _canDeleteFromLibrary = false;

  String _normPath(String p) => p.replaceAll('/', '\\').toLowerCase();

  // 蛟呵｣徼ag縺ｮ繧ｭ繝｣繝・す繝･
  List<TagWithId> _masterTags = const [];
  bool _masterLoading = false;
  final TextEditingController _masterFilterCtrl = TextEditingController();

  TagCategory _selectedCategory = TagCategory.free;
  final TextEditingController _tagCtrl = TextEditingController();
  bool _tagsLoading = false;
  String? _loadedTagItemId;
  bool _masterTagsInitialized = false;
  int _detailLoadVersion = 0;

  ReaderFitMode _fitMode = ReaderFitMode.vertical;

  Future<Uint8List>? _leftFuture;
  Future<Uint8List>? _rightFuture;

  final Map<int, Future<Uint8List>> _readerFutureCache = {};
  final Map<int, Future<Uint8List>> _thumbFutureCache = {};

  MediaItem get _item => _items[_index];
  bool get _isPdf => _item.kind == MediaKind.pdf;
  bool get _canRenameCurrentItem => widget.repo.capabilities.canRename;
  String get _displayTitle =>
      ItemNameService.formatMediaTitle(_item.displayName, kind: _item.kind);

  void _popWithResult() {
    Navigator.of(context).pop(_favChanged || _tagsChanged || _itemChanged);
  }

  static const _uiBg = Color(0xFF0F0F10);
  static const _uiBar = Color(0xFF1F1F1F);
  static const _uiChip = Color(0xFF2B2B2B);

  String _basename(String raw) {
    if (raw.trim().isEmpty) return raw;

    // Windows繝代せ縺ｪ繧画怙蠕後・隕∫ｴ
    if (raw.contains('\\') || raw.contains('/')) {
      var s = raw.replaceAll('\\', '/');
      final slash = s.lastIndexOf('/');
      if (slash >= 0 && slash + 1 < s.length) return s.substring(slash + 1);
      return s;
    }

    // Android縺ｮtreeUri縺ｪ縺ｩ縺ｮcontent:// 縺ｮ蝣ｴ蜷・
    try {
      var s = raw;

      // 荳牙屓縺ｻ縺ｩ蝗槭☆縲・
      for (int i = 0; i < 3; i++) {
        if (!s.contains('%')) break;
        s = Uri.decodeComponent(s);
      }

      // primary: 縺ｪ縺ｩ縺ｮ繝懊Μ繝･繝ｼ繝蜷阪ｒ關ｽ縺ｨ縺励※縺ｿ繧九・
      final colon = s.indexOf(':');
      if (colon >= 0) s = s.substring(colon + 1);

      // 譛蠕後・繝代せ隕∫ｴ縺縺・
      s = s.replaceAll('\\', '/');
      final slash = s.lastIndexOf('/');
      if (slash >= 0) s = s.substring(slash + 1);

      return s.trim().isEmpty ? raw : s.trim();
    } catch (_) {
      return raw;
    }
  }

  @override
  void initState() {
    super.initState();

    _items = widget.items;
    _index = widget.initialIndex;
    _page = widget.initialPdfPage ?? 1;

    _tab = TabController(length: 2, vsync: this);

    _tab.addListener(() {
      if (_tab.indexIsChanging) return;
      final inReader = _tab.index == 0;
      if (inReader != _inReader) {
        setState(() => _inReader = inReader);
      }
      if (!inReader) {
        _ensureDeferredDetailData();
      }
    });

    _initAsync();
  }

  Future<void> _initAsync() async {
    final prefs = await SharedPreferences.getInstance();
    final fitIndex = prefs.getInt(_PrefsKeys.fitMode);
    final two = prefs.getBool(_PrefsKeys.twoPage);
    if (fitIndex != null &&
        fitIndex >= 0 &&
        fitIndex < ReaderFitMode.values.length) {
      _fitMode = ReaderFitMode.values[fitIndex];
    }
    if (two != null) _twoPage = two;
    if (widget.repo.isRemoteMode) {
      _folder = FolderHandle(_item.folderRaw);
    } else {
      final raw = prefs.getString(_PrefsKeys.lastFolderRaw);
      if (raw != null && raw.isNotEmpty) {
        _folder = FolderHandle(raw);
      }
    }
    if (!mounted) return;
    setState(() {});
    _reloadForCurrent();
    unawaited(_loadLibraryContext());
  }

  Future<void> _loadLibraryContext() async {
    try {
      final lib = await widget.repo.getAppLibraryFolder();
      if (!mounted) return;
      setState(() {
        _libraryRootRaw = lib.raw;
        _canDeleteFromLibrary = widget.repo.capabilities.canDelete && _isPdf;
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _masterFilterCtrl.dispose();
    _tagCtrl.dispose();
    _tab.dispose();
    if (_fullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  Future<void> _saveFitMode(ReaderFitMode v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_PrefsKeys.fitMode, v.index);
  }

  Future<void> _saveTwoPage(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_PrefsKeys.twoPage, v);
  }

  bool _isCurrentLoad(int loadVersion, MediaItem item) {
    return mounted && loadVersion == _detailLoadVersion && _item.id == item.id;
  }

  void _ensureDeferredDetailData() {
    if (_loadedTagItemId != _item.id && !_tagsLoading) {
      unawaited(_loadTagsForCurrent());
    }
    if (!_masterTagsInitialized && !_masterLoading) {
      _masterTagsInitialized = true;
      unawaited(_loadMasterTags());
    }
  }

  Future<void> _loadFavoriteForCurrent({int? loadVersion}) async {
    final item = _item;
    final version = loadVersion ?? _detailLoadVersion;
    final prefs = await SharedPreferences.getInstance();
    final favList =
        prefs.getStringList(_PrefsKeys.favorites) ?? const <String>[];
    final fav = favList.contains(item.id);
    if (!_isCurrentLoad(version, item)) return;
    setState(() => _isFavorite = fav);
  }

  Future<void> _toggleFavorite() async {
    final prefs = await SharedPreferences.getInstance();
    final favList =
        prefs.getStringList(_PrefsKeys.favorites) ?? const <String>[];
    final next = favList.toSet();

    if (next.contains(_item.id)) {
      next.remove(_item.id);
      setState(() => _isFavorite = false);
    } else {
      next.add(_item.id);
      setState(() => _isFavorite = true);
    }

    _favChanged = true;
    await prefs.setStringList(
      _PrefsKeys.favorites,
      next.toList(growable: false),
    );
  }

  Future<void> _saveLastFolder(FolderHandle folder) async {
    if (widget.repo.isRemoteMode) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_PrefsKeys.lastFolderRaw, folder.raw);
  }

  // ----------------
  // Tags (SharedPreferences萓晏ｭ・

  String? _normalizeTag(String input) {
    var t = input.trim();
    if (t.isEmpty) return null;
    if (t.startsWith('#')) t = t.substring(1);
    t = t.trim();
    if (t.isEmpty) return null;
    // 遨ｺ逋ｽ縺ｯ遖∵ｭ｢
    if (t.contains(RegExp(r'\s'))) return null;
    return t;
  }

  Future<void> _loadMasterTags({String? contains}) async {
    _masterTagsInitialized = true;
    setState(() => _masterLoading = true);
    try {
      final list = await widget.tagService.listTagMasterByCategory(
        _selectedCategory,
        contains: contains,
        limit: 300,
      );
      if (!mounted) return;
      setState(() => _masterTags = list);
    } finally {
      if (mounted) setState(() => _masterLoading = false);
    }
  }

  Future<void> _loadTagsForCurrent({bool force = false, int? loadVersion}) async {
    final item = _item;
    final version = loadVersion ?? _detailLoadVersion;
    if (!force && _loadedTagItemId == item.id) {
      return;
    }

    setState(() {
      _tagsLoading = true;
      if (_loadedTagItemId != item.id) {
        _tags = const [];
      }
    });
    try {
      final list = await widget.tagService.listTagsForItem(
        item.id,
        item: item,
      );
      if (!_isCurrentLoad(version, item)) return;
      setState(() {
        _tags = list;
        _loadedTagItemId = item.id;
      });
    } finally {
      if (_isCurrentLoad(version, item)) {
        setState(() => _tagsLoading = false);
      }
    }
  }

  Future<void> _addExistingMasterTag(TagWithId t) async {
    try {
      await widget.tagService.addTagToItem(_item, t.tag);
      _tagsChanged = true;
      await _loadTagsForCurrent(force: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('タグ追加に失敗しました: $e')));
    }
  }

  Future<void> _addTagFromUi() async {
    final raw = _tagCtrl.text;
    final name = _normalizeTag(raw);
    if (name == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(
        const SnackBar(content: Text('タグ名が無効です（空白を含めずに入力してください）')),
      );
      return;
    }

    final tag = Tag(name: name, category: _selectedCategory);

    try {
      await widget.tagService.addTagToItem(_item, tag);

      _tagsChanged = true;
      _tagCtrl.clear();
      await _loadTagsForCurrent(force: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('タグ追加に失敗しました: $e')));
    }
  }

  Future<void> _removeTagFromUi(TagWithId t) async {
    try {
      await widget.tagService.removeTagFromItem(
        _item.id,
        t.tagId,
        item: _item,
      );
      _tagsChanged = true;
      await _loadTagsForCurrent(force: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('タグ削除に失敗しました: $e')));
    }
  }

  BoxFit get _boxFit {
    switch (_fitMode) {
      case ReaderFitMode.vertical:
        return BoxFit.fitHeight;
      case ReaderFitMode.horizontal:
        return BoxFit.fitWidth;
      case ReaderFitMode.contain:
        return BoxFit.contain;
    }
  }

  Future<Uint8List> _loadReaderBytes(MediaItem item, int page) {
    return _readerFutureCache.putIfAbsent(page, () {
      return widget.repo.renderPageBytes(item, page, maxWidth: 1600);
    });
  }

  Future<Uint8List> _loadThumbBytes(MediaItem item, int page) {
    return _thumbFutureCache.putIfAbsent(page, () {
      return widget.repo.renderPageBytes(item, page, maxWidth: 320);
    });
  }

  void _syncReaderFutures(MediaItem item) {
    _leftFuture = _loadReaderBytes(item, _page);

    if (_twoPage && _isPdf) {
      final nextPage = _page + 1;
      _rightFuture = nextPage <= _totalPages
          ? _loadReaderBytes(item, nextPage)
          : null;
      return;
    }

    _rightFuture = null;
  }

  void _setCurrentPdfPage(int page) {
    setState(() {
      _page = page.clamp(1, _totalPages);
      _syncReaderFutures(_item);
    });
  }

  Future<void> _loadPageCountForCurrent(
    MediaItem item,
    int loadVersion,
  ) async {
    try {
      final total = await widget.repo.getPageCount(item);
      if (!_isCurrentLoad(loadVersion, item)) return;

      setState(() {
        _totalPages = total < 1 ? 1 : total;
        _page = _page.clamp(1, _totalPages);
        _syncReaderFutures(item);
      });
    } catch (error) {
      if (!_isCurrentLoad(loadVersion, item)) return;
      setState(() {
        _totalPages = 1;
        _page = 1;
        _syncReaderFutures(item);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ページ情報の取得に失敗しました: $error')),
      );
    }
  }

  Future<void> _reloadForCurrent() async {
    final item = _item;
    final loadVersion = ++_detailLoadVersion;

    _readerFutureCache.clear();
    _thumbFutureCache.clear();
    _loadedTagItemId = null;
    if (mounted) {
      setState(() {
        _isFavorite = false;
        _tags = const [];
        _tagsLoading = false;
        _canDeleteFromLibrary =
            widget.repo.capabilities.canDelete && item.kind == MediaKind.pdf;
        _totalPages = item.kind == MediaKind.pdf ? _totalPages : 1;
        _page = item.kind == MediaKind.pdf ? _page.clamp(1, _totalPages) : 1;
        _syncReaderFutures(item);
      });
    }

    unawaited(_loadFavoriteForCurrent(loadVersion: loadVersion));
    if (item.kind == MediaKind.pdf) {
      unawaited(_loadPageCountForCurrent(item, loadVersion));
    }
    if (!_inReader) {
      _ensureDeferredDetailData();
    }
  }

  Widget _buildLoadError(
    String message, {
    required VoidCallback onRetry,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.cloud_off_outlined,
              color: Colors.white70,
              size: 34,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('再試行'),
            ),
          ],
        ),
      ),
    );
  }

  void _next() {
    if (_isPdf) {
      final step = _twoPage ? 2 : 1;
      final next = _page + step;
      if (next <= _totalPages) {
        _setCurrentPdfPage(next);
      }
    } else {
      if (_index < _items.length - 1) {
        setState(() {
          _index++;
          _page = 1;
        });
        _reloadForCurrent();
      }
    }
  }

  void _prev() {
    if (_isPdf) {
      final step = _twoPage ? 2 : 1;
      final prev = _page - step;
      if (prev >= 1) {
        _setCurrentPdfPage(prev);
      }
    } else {
      if (_index > 0) {
        setState(() {
          _index--;
          _page = 1;
        });
        _reloadForCurrent();
      }
    }
  }

  Future<void> _renameCurrentItem() async {
    final item = _item;
    final newBase = await showRenameItemDialog(context, item: item);

    if (newBase == null || newBase.isEmpty) return;

    try {
      final updated = await widget.repo.rename(item, newBase);
      String? metadataWarning;
      try {
        await widget.tagService.handleItemRenamed(item, updated);
      } catch (e) {
        metadataWarning = 'メタデータの更新に失敗しました: $e';
      }
      final prefs = await SharedPreferences.getInstance();
      final favorites = (prefs.getStringList(_PrefsKeys.favorites) ?? const <String>[])
          .toSet();
      if (favorites.remove(item.id)) {
        favorites.add(updated.id);
        await prefs.setStringList(
          _PrefsKeys.favorites,
          favorites.toList(growable: false),
        );
      }
      if (!mounted) return;

      setState(() {
        _items[_index] = updated;
        _isFavorite = favorites.contains(updated.id);
      });
      _itemChanged = true;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('名前を変更しました: ${updated.displayName}')),
      );
      if (metadataWarning != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(metadataWarning)));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('名前の変更に失敗しました: $e')));
    }
  }

  Future<void> _toggleFullscreen() async {
    setState(() => _fullscreen = !_fullscreen);
    if (_fullscreen) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
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

  Future<void> _deleteCurrentItemWithWarning() async {
    if (!_canDeleteFromLibrary) return;

    final item = _item;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('この PDF を削除しますか？'),
        content: Text(
          '「${item.displayName}」を削除します。\n'
          '削除すると元に戻せません。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    // 螳溷炎髯､
    final bool deleted;
    try {
      deleted = await widget.repo.deleteItem(item);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('削除に失敗しました: $error')));
      return;
    }
    if (!mounted) return;

    if (!deleted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('削除に失敗しました')),
      );
      return;
    }

    String? metadataWarning;
    try {
      await widget.tagService.handleDeletedItems([item]);
    } catch (e) {
      metadataWarning = 'メタデータ削除に失敗しました: $e';
    }

    // 縺頑ｰ励↓蜈･繧翫↓谿九▲縺ｦ繧九→繧ｴ繝溘↓縺ｪ繧九・縺ｧ螟悶☆
    final prefs = await SharedPreferences.getInstance();
    final fav = (prefs.getStringList(_PrefsKeys.favorites) ?? const <String>[])
        .toSet();
    fav.remove(item.id);
    await prefs.setStringList(_PrefsKeys.favorites, fav.toList(growable: false));

    if (metadataWarning != null && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(metadataWarning)));
    }

    // 隧ｳ邏ｰ逕ｻ髱｢繧帝哩縺倥※荳隕ｧ蛛ｴ縺ｧ繝ｪ繝ｭ繝ｼ繝峨＆縺帙ｋ
    if (!mounted) return;
    Navigator.pop(context, true);
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
    final title = _displayTitle;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('詳細メニュー', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
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
                _reloadForCurrent();
              },
            ),
            const Divider(),
            _sidebarSectionLabel('フォルダ'),
            ListTile(
              title: Text(_folder?.raw ?? '\u672a\u9078\u629e'),
              subtitle: Text(!widget.repo.capabilities.canPickFolder
                  ? '\u30ea\u30e2\u30fc\u30c8\u30e2\u30fc\u30c9\u3067\u306f\u73fe\u5728\u306e\u30d5\u30a9\u30eb\u30c0\u3092\u8868\u793a\u4e2d'
                  : '\u8868\u793a\u3059\u308b\u30d5\u30a9\u30eb\u30c0\u306b\u5207\u308a\u66ff\u3048'),
              trailing: const Icon(Icons.folder_open),
              onTap: !widget.repo.capabilities.canPickFolder
                  ? null
                  : () async {
                      _closeSidebar();
                      final folder = await widget.repo.pickFolder();
                      if (folder == null) return;
                      final items = await widget.repo.listMedia(folder);
                      if (!mounted) return;
                      await _saveLastFolder(folder);
                      setState(() {
                        _folder = folder;
                        _items = items;
                        _index = 0;
                        _page = 1;
                      });
                      _reloadForCurrent();
                    },
            ),
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
    final wide = _isWideLayout(context);

    return WillPopScope(
      onWillPop: () async {
        _popWithResult();
        return false;
      },
      child: Scaffold(
        drawer: wide ? null : _buildSidebar(),
        backgroundColor: _uiBg,
        appBar: AppBar(
          backgroundColor: _uiBar,
          foregroundColor: Colors.white,

          title: Row(
            children: [
              Expanded(
                child: Text(
                  _displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_inReader) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      reverse: true, // 蜿ｳ遶ｯ・域桃菴懷・・峨ｒ隕九○繧・☆縺上☆繧・
                      child: _topReaderControls(),
                    ),
                  ),
                ),
              ],
            ],
          ),

          leadingWidth: wide ? 56 : 96,
          leading: Row(
            children: [
              IconButton(
                tooltip: '戻る',
                icon: const Icon(Icons.arrow_back),
                onPressed: _popWithResult,
              ),
              if (!wide)
                Builder(
                  builder: (ctx) => IconButton(
                    tooltip: 'メニュー',
                    icon: const Icon(Icons.menu),
                    onPressed: () => Scaffold.of(ctx).openDrawer(),
                  ),
                ),
            ],
          ),

          actions: [
            IconButton(
              tooltip: _isFavorite ? 'お気に入りを解除' : 'お気に入りに追加',
              onPressed: _toggleFavorite,
              icon: Icon(_isFavorite ? Icons.star : Icons.star_border),
            ),
            IconButton(
              tooltip: _fullscreen ? 'フルスクリーン解除' : 'フルスクリーン',
              onPressed: _toggleFullscreen,
              icon: Icon(
                _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
              ),
            ),
            if (_canDeleteFromLibrary)
            PopupMenuButton<_DetailMenuAction>(
              tooltip: 'メニュー',
              onSelected: (a) {
                if (a == _DetailMenuAction.delete) {
                  _deleteCurrentItemWithWarning();
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: _DetailMenuAction.delete,
                  child: ListTile(
                    leading: Icon(Icons.delete_outline),
                    title: Text('PDF を削除'),
                  ),
                ),
              ],
            ),
          ],
          bottom: TabBar(
            controller: _tab,
            tabs: const [
              Tab(text: '閲覧'),
              Tab(text: '詳細'),
            ],
          ),
        ),

        body: _withSidebar(context, Shortcuts(
          shortcuts: const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.arrowLeft): _PrevIntent(),
            SingleActivator(LogicalKeyboardKey.arrowRight): _NextIntent(),
            SingleActivator(LogicalKeyboardKey.escape): _EscapeIntent(),
          },
          child: Actions(
            actions: <Type, Action<Intent>>{
              _PrevIntent: CallbackAction<_PrevIntent>(
                onInvoke: (intent) {
                  // 髢ｲ隕ｧ逕ｨ繧ｿ繝悶・縺ｨ縺阪□縺代・繝ｼ繧ｸ繧堤ｧｻ蜍・
                  if (_tab.index == 0) _prev();
                  return null;
                },
              ),
              _NextIntent: CallbackAction<_NextIntent>(
                onInvoke: (intent) {
                  if (_tab.index == 0) _next();
                  return null;
                },
              ),
              _EscapeIntent: CallbackAction<_EscapeIntent>(
                onInvoke: (intent) {
                  if (_fullscreen) {
                    _toggleFullscreen();
                  } else {
                    _popWithResult(); // Grid繝壹・繧ｸ縺ｸ謌ｻ繧・
                  }
                  return null;
                },
              ),
            },
            child: Focus(
              autofocus: true,
              child: AnimatedBuilder(
                animation: _tab,
                builder: (context, _) {
                  if (_tab.index == 0) return _buildReader();
                  return _buildDetail();
                },
              ),
            ),
          ),
        )),
      ),
    );
  }

  Widget _buildReader() {
    return Stack(
      children: [
        Center(
          child: LayoutBuilder(
            builder: (context, c) {
              const gap = 0.0;

              final isSpread = _twoPage && _isPdf;
              final pageW = isSpread ? (c.maxWidth - gap) / 2.0 : c.maxWidth;

              return Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: pageW,
                    child: _pageImage(
                      _leftFuture,
                      align: isSpread
                          ? Alignment.centerRight
                          : Alignment.center,
                      isSpread: isSpread,
                      pageNumber: _page,
                    ),
                  ),
                  if (isSpread) ...[
                    const SizedBox(width: gap),
                    SizedBox(
                      width: pageW,
                      child: _pageImage(
                        _rightFuture,
                        align: Alignment.centerLeft,
                        isSpread: isSpread,
                        pageNumber: _page + 1,
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),

        // 遶ｯ譛ｫ繧ｿ繝・・縺ｧ繝壹・繧ｸ驕ｷ遘ｻ・亥ｷｦ=蜑・/ 蜿ｳ=谺｡・・
        Positioned.fill(
          child: LayoutBuilder(
            builder: (context, c) {
              return GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTapUp: (details) {
                  // 髢ｲ隕ｧ逕ｨ繧ｿ繝紋ｻ･螟悶・辟｡隕悶☆繧・
                  if (_tab.index != 0) return;

                  final dx = details.localPosition.dx;
                  final w = c.maxWidth;

                  // 荳ｭ螟ｮ縺ｯ辟｡蜿榊ｿ懊↓
                  final leftEdge = w * 0.35;
                  final rightEdge = w * 0.65;

                  if (dx < leftEdge) {
                    _prev(); // 蟾ｦ繧ｿ繝・・ 竊・蜑・
                  } else if (dx > rightEdge) {
                    _next(); // 蜿ｳ繧ｿ繝・・ 竊・谺｡
                  }
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _pageImage(
    Future<Uint8List>? future, {
    required Alignment align,
    required bool isSpread,
    required int pageNumber,
  }) {
    if (future == null) return const SizedBox.shrink();

    return FutureBuilder<Uint8List>(
      future: future,
      builder: (context, snap) {
        if (snap.hasError) {
          return _buildLoadError(
            '画像の読み込みに失敗しました。\n${snap.error}',
            onRetry: () {
              setState(() {
                _readerFutureCache.remove(pageNumber);
                _syncReaderFutures(_item);
              });
            },
          );
        }

        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        // 隕矩幕縺阪・縲檎ｸｦ蜷医ｏ縺帙搾ｼ九檎ｶｴ縺伜・蟇・○縲阪′荳逡ｪ螳牙ｮ壹＠繧・☆縺九▲縺・
        final fit = isSpread ? BoxFit.fitHeight : _boxFit;

        //pdf縺ｮ閭梧勹縺ｫ逋ｽ繧定ｿｽ蜉・磯乗・縺ｧ騾上￠縺ｦ隕九∴繧具ｼ・
        final img = Image.memory(
          snap.data!,
          fit: fit,
          alignment: align,
          gaplessPlayback: true,
          filterQuality: FilterQuality.high,
        );

        final widgetToShow = _isPdf
            ? DecoratedBox(
                decoration: const BoxDecoration(color: Colors.white),
                child: img,
              )
            : img;
        return InteractiveViewer(
          minScale: 0.5,
          maxScale: 6,
          alignment: align,
          child: Align(alignment: align, child: widgetToShow),
        );
      },
    );
  }

  Widget _buildDetail() {
    final item = _item;

    return Padding(
      padding: const EdgeInsets.all(12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 荳九↓陦ｨ遉ｺ縺吶ｋ繧ｰ繝ｪ繝・ラ縺ｮ鬮倥＆縲∫判髱｢35・・⊇縺ｩ繧貞盾辣ｧ
          final gridHeight = (constraints.maxHeight * 0.35).clamp(180.0, 420.0);

          return SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _infoRow('種別', item.kind == MediaKind.pdf ? 'PDF' : '画像'),
                const SizedBox(height: 8),
                if (_isPdf) _infoRow('ページ', '$_totalPages'),
                const SizedBox(height: 8),
                _infoRow('フォルダ', _basename(item.folderRaw)),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(
                      width: 64,
                      child: Text(
                        '名前',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SelectableText(
                        ItemNameService.formatMediaTitle(
                          item.displayName,
                          kind: item.kind,
                        ),
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                    if (_canRenameCurrentItem)
                      IconButton(
                        tooltip: '名前を変更',
                        icon: const Icon(Icons.edit, color: Colors.white),
                        onPressed: _renameCurrentItem,
                      ),
                  ],
                ),

                // Tags・医ち繧ｰ・・
                const SizedBox(height: 10),
                LayoutBuilder(
                  builder: (context, c) {
                    final narrow = c.maxWidth < 520;

                    final categoryField = DropdownButtonHideUnderline(
                      child: DropdownButton<TagCategory>(
                        value: _selectedCategory,
                        isDense: true,
                        items: const [
                          DropdownMenuItem(
                            value: TagCategory.artist,
                            child: Text('作家'),
                          ),
                          DropdownMenuItem(
                            value: TagCategory.series,
                            child: Text('シリーズ'),
                          ),
                          DropdownMenuItem(
                            value: TagCategory.mediaType,
                            child: Text('メディア種別'),
                          ),
                          DropdownMenuItem(
                            value: TagCategory.character,
                            child: Text('キャラ'),
                          ),
                          DropdownMenuItem(
                            value: TagCategory.free,
                            child: Text('自由'),
                          ),
                        ],
                        onChanged: (v) async {
                          if (v == null) return;
                          setState(() => _selectedCategory = v);
                          await _loadMasterTags(); // 笘・呵｣懊ｒ繧ｫ繝・ざ繝ｪ縺斐→縺ｫ譖ｴ譁ｰ
                        },
                      ),
                    );

                    final inputField = TextField(
                      controller: _tagCtrl,
                      decoration: const InputDecoration(
                        hintText: 'タグ名を入力 / 空白は不可',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _addTagFromUi(),
                    );

                    final addButton = FilledButton.icon(
                      onPressed: _addTagFromUi,
                      icon: const Icon(Icons.add),
                      label: const Text('追加'),
                    );

                    if (!narrow) {
                      return Row(
                        children: [
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 180),
                            child: categoryField,
                          ),
                          const SizedBox(width: 8),
                          Expanded(child: inputField),
                          const SizedBox(width: 8),
                          addButton,
                        ],
                      );
                    }

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        categoryField,
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(child: inputField),
                            const SizedBox(width: 8),
                            addButton,
                          ],
                        ),
                      ],
                    );
                  },
                ),

                const SizedBox(height: 10),

                if (_tagsLoading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: LinearProgressIndicator(),
                  ),

                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final t in _tags)
                      InputChip(
                        label: Text(
                          '#${t.tag.name}',
                          style: const TextStyle(color: Colors.white),
                        ),
                        backgroundColor: _uiChip,
                        deleteIconColor: Colors.white70,
                        onDeleted: () => _removeTagFromUi(t),
                      ),
                  ],
                ),

                // --- Tags (繧ｫ繝・ざ繝ｪ蛟呵｣・ ---
                const SizedBox(height: 14),

                Row(
                  children: [
                    const Text('タグ候補（このカテゴリ）'),
                    const SizedBox(width: 8),
                    if (_masterLoading)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    const Spacer(),
                    IconButton(
                      tooltip: '再読み込み',
                      onPressed: () =>
                          _loadMasterTags(contains: _masterFilterCtrl.text),
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),

                const SizedBox(height: 8),

                SizedBox(
                  height: 44,
                  child: TextField(
                    controller: _masterFilterCtrl,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: '候補を絞り込み（部分一致）',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      suffixIcon: (_masterFilterCtrl.text.trim().isEmpty)
                          ? null
                          : IconButton(
                              tooltip: 'クリア',
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                _masterFilterCtrl.clear();
                                _loadMasterTags();
                                setState(() {});
                              },
                            ),
                    ),
                    onChanged: (v) {
                      _loadMasterTags(contains: v);
                      setState(() {});
                    },
                  ),
                ),

                const SizedBox(height: 10),

                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 180),
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final t in _masterTags)
                          ActionChip(
                            label: Text('#${t.tag.name}'),
                            onPressed: () => _addExistingMasterTag(t),
                          ),
                        if (_masterTags.isEmpty && !_masterLoading)
                          const Text('タグ候補がありません。追加するとここに表示されます。'),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                // --- PDF繧偵せ繧ｯ繝ｭ繝ｼ繝ｫ蜀・↓蝗ｺ螳夐ｫ倥＆縺ｧ蜈･繧後ｋ ---
                if (_isPdf)
                  SizedBox(height: gridHeight, child: _buildPdfThumbGrid(item))
                else
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Center(
                      child: Text(
                        '画像はサムネイル一覧がありません',
                        style: Theme.of(
                          context,
                        ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _topReaderControls() {
    final canPrev = _isPdf ? (_page > 1) : (_index > 0);
    final canNext = _isPdf
        ? (_page + (_twoPage ? 2 : 1) <= _totalPages)
        : (_index < _items.length - 1);

    final pageText = _isPdf
        ? '$_page/$_totalPages'
        : '${_index + 1}/${_items.length}';

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: '前',
          onPressed: canPrev ? _prev : null,
          icon: const Icon(Icons.chevron_left),
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        ),
        IconButton(
          tooltip: '谺｡',
          onPressed: canNext ? _next : null,
          icon: const Icon(Icons.chevron_right),
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          margin: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: _uiChip,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            pageText,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),

        // 隕矩幕縺阪・PDF縺縺・
        if (_isPdf)
          TextButton.icon(
            style: TextButton.styleFrom(
              foregroundColor: Colors.white,
              backgroundColor: _uiChip,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              visualDensity: VisualDensity.compact,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            icon: const Icon(Icons.swap_horiz, size: 18),
            label: Text(
              _twoPage ? '見開き ON' : '見開き OFF',
              style: const TextStyle(fontSize: 12),
            ),
            onPressed: () async {
              final v = !_twoPage;
              setState(() => _twoPage = v);
              await _saveTwoPage(v);
              _reloadForCurrent();
            },
          ),

        const SizedBox(width: 6),

        // Fit ・亥・菴薙ｒ陦ｨ遉ｺ縺吶ｋ繝｢繝ｼ繝会ｼ・
        PopupMenuButton<ReaderFitMode>(
          tooltip: 'Fit',
          initialValue: _fitMode,
          onSelected: (v) async {
            setState(() => _fitMode = v);
            await _saveFitMode(v);
          },
          itemBuilder: (context) => const [
            PopupMenuItem(value: ReaderFitMode.vertical, child: Text('縦フィット')),
            PopupMenuItem(
              value: ReaderFitMode.horizontal,
              child: Text('横フィット'),
            ),
            PopupMenuItem(
              value: ReaderFitMode.contain,
              child: Text('全体表示 (Contain)'),
            ),
          ],
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: _uiChip,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.aspect_ratio, size: 18, color: Colors.white),
                const SizedBox(width: 6),
                Text(switch (_fitMode) {
                  ReaderFitMode.vertical => '縦',
                  ReaderFitMode.horizontal => '横',
                  ReaderFitMode.contain => '全体',
                }, style: const TextStyle(color: Colors.white, fontSize: 12)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPdfThumbGrid(MediaItem item) {
    final total = _totalPages;

    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 0.75,
      ),
      itemCount: total,
      itemBuilder: (context, i) {
        final page = i + 1;

        return InkWell(
          onTap: () {
            _setCurrentPdfPage(page);
            _tab.animateTo(0);
          },
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: _uiChip,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: page == _page ? Colors.white : Colors.transparent,
                width: 2,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: FutureBuilder<Uint8List>(
                future: _loadThumbBytes(item, page),
                builder: (context, snap) {
                  if (snap.hasError) {
                    return _buildLoadError(
                      'ページ $page のサムネイル取得に失敗しました。',
                      onRetry: () {
                        setState(() {
                          _thumbFutureCache.remove(page);
                        });
                      },
                    );
                  }
                  if (!snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  return Image.memory(
                    snap.data!,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.low,
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _infoRow(String k, String v) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 64,
          child: Text(k, style: const TextStyle(color: Colors.white70)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: SelectableText(v, style: const TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}

class _PrevIntent extends Intent {
  const _PrevIntent();
}

class _NextIntent extends Intent {
  const _NextIntent();
}

class _EscapeIntent extends Intent {
  const _EscapeIntent();
}


