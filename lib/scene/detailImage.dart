import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/folder.dart';
import '../models/mediaItem.dart';
import '../repository/mediaRepository.dart';

import '../database/tag_service.dart';
import '../models/tag.dart';

enum ReaderFitMode { vertical, horizontal, contain }

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

  // tag（タグ）
  List<TagWithId> _tags = const [];
  bool _tagsChanged = false;

  // 候補tagのキャッシュ
  List<TagWithId> _masterTags = const [];
  bool _masterLoading = false;
  final TextEditingController _masterFilterCtrl = TextEditingController();

  TagCategory _selectedCategory = TagCategory.free;
  final TextEditingController _tagCtrl = TextEditingController();
  bool _tagsLoading = false;

  ReaderFitMode _fitMode = ReaderFitMode.vertical;

  Future<Uint8List>? _leftFuture;
  Future<Uint8List>? _rightFuture;

  final Map<int, Future<Uint8List>> _readerFutureCache = {};
  final Map<int, Future<Uint8List>> _thumbFutureCache = {};

  MediaItem get _item => _items[_index];
  bool get _isPdf => _item.kind == MediaKind.pdf;

  void _popWithResult() {
    Navigator.of(context).pop(_favChanged || _tagsChanged);
  }

  static const _uiBg = Color(0xFF0F0F10);
  static const _uiBar = Color(0xFF1F1F1F);
  static const _uiChip = Color(0xFF2B2B2B);

  String _basename(String raw) {
    if (raw.trim().isEmpty) return raw;

    // Windowsパスなら最後の要素
    if (raw.contains('\\') || raw.contains('/')) {
      var s = raw.replaceAll('\\', '/');
      final slash = s.lastIndexOf('/');
      if (slash >= 0 && slash + 1 < s.length) return s.substring(slash + 1);
      return s;
    }

    // AndroidのtreeUriなどのcontent:// の場合
    try {
      var s = raw;

      // 三回ほど回す。
      for (int i = 0; i < 3; i++) {
        if (!s.contains('%')) break;
        s = Uri.decodeComponent(s);
      }

      // primary: などのボリューム名を落としてみる。
      final colon = s.indexOf(':');
      if (colon >= 0) s = s.substring(colon + 1);

      // 最後のパス要素だけ
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
      if (!_tab.indexIsChanging) {
        final v = _tab.index == 0;
        if (v != _inReader) setState(() => _inReader = v);
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

    final raw = prefs.getString(_PrefsKeys.lastFolderRaw);
    if (raw != null && raw.isNotEmpty) {
      _folder = FolderHandle(raw);
    }

    if (!mounted) return;
    setState(() {});
    await _loadFavoriteForCurrent();
    _reloadForCurrent();
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

  Future<void> _loadFavoriteForCurrent() async {
    final prefs = await SharedPreferences.getInstance();
    final favList =
        prefs.getStringList(_PrefsKeys.favorites) ?? const <String>[];
    final fav = favList.contains(_item.id);
    if (!mounted) return;
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
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_PrefsKeys.lastFolderRaw, folder.raw);
  }

  // ----------------
  // Tags (SharedPreferences依存)

  String? _normalizeTag(String input) {
    var t = input.trim();
    if (t.isEmpty) return null;
    if (t.startsWith('#')) t = t.substring(1);
    t = t.trim();
    if (t.isEmpty) return null;
    // 空白は禁止
    if (t.contains(RegExp(r'\s'))) return null;
    return t;
  }

  Future<void> _loadMasterTags({String? contains}) async {
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

  Future<void> _loadTagsForCurrent() async {
    setState(() => _tagsLoading = true);
    try {
      final list = await widget.tagService.listTagsForItem(_item.id);
      if (!mounted) return;
      setState(() => _tags = list);
    } finally {
      if (mounted) setState(() => _tagsLoading = false);
    }
  }

  Future<void> _addExistingMasterTag(TagWithId t) async {
    await widget.tagService.addTagToItem(_item, t.tag);
    _tagsChanged = true;
    await _loadTagsForCurrent();
  }

  Future<void> _addTagFromUi() async {
    final raw = _tagCtrl.text;
    final name = _normalizeTag(raw);
    if (name == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('タグが無効です（空白なしで入力してください)')));
      return;
    }

    final tag = Tag(name: name, category: _selectedCategory);

    await widget.tagService.addTagToItem(_item, tag);

    _tagsChanged = true;
    _tagCtrl.clear();
    await _loadTagsForCurrent();
  }

  Future<void> _removeTagFromUi(TagWithId t) async {
    await widget.tagService.removeTagFromItem(_item.id, t.tagId);
    _tagsChanged = true;
    await _loadTagsForCurrent();
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

  Future<void> _reloadForCurrent() async {
    final item = _item;

    await _loadFavoriteForCurrent();

    _readerFutureCache.clear();
    _thumbFutureCache.clear();

    final total = await widget.repo.getPageCount(item);
    if (!mounted) return;

    setState(() {
      _totalPages = total;
      _page = _isPdf ? _page.clamp(1, _totalPages) : 1;

      _leftFuture = _loadReaderBytes(item, _page);

      if (_twoPage && _isPdf) {
        final next = _page + 1;
        _rightFuture = (next <= _totalPages)
            ? _loadReaderBytes(item, next)
            : null;
      } else {
        _rightFuture = null;
      }
    });
    await _loadTagsForCurrent();
    await _loadMasterTags();
  }

  void _next() {
    if (_isPdf) {
      final step = _twoPage ? 2 : 1;
      final next = _page + step;
      if (next <= _totalPages) {
        setState(() => _page = next);
        _leftFuture = _loadReaderBytes(_item, _page);
        if (_twoPage) {
          final p2 = _page + 1;
          _rightFuture = (p2 <= _totalPages)
              ? _loadReaderBytes(_item, p2)
              : null;
        } else {
          _rightFuture = null;
        }
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
        setState(() => _page = prev);
        _leftFuture = _loadReaderBytes(_item, _page);
        if (_twoPage) {
          final p2 = _page + 1;
          _rightFuture = (p2 <= _totalPages)
              ? _loadReaderBytes(_item, p2)
              : null;
        } else {
          _rightFuture = null;
        }
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

  Future<void> _renameCurrentPdf() async {
    final item = _item;
    if (item.kind != MediaKind.pdf) return;

    final base = item.displayName.toLowerCase().endsWith('.pdf')
        ? item.displayName.substring(0, item.displayName.length - 4)
        : item.displayName;

    final ctrl = TextEditingController(text: base);

    final newBase = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('PDFの名前を変更'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '拡張子 .pdf は不要',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: const Text('変更'),
          ),
        ],
      ),
    );

    if (newBase == null || newBase.isEmpty) return;

    try {
      final updated = await widget.repo.rename(item, newBase);
      if (!mounted) return;

      setState(() {
        _items[_index] = updated; // AppBarのtitle も更新される
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('名前を変更しました: ${updated.displayName}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('名前変更に失敗: $e')));
    } finally {
      ctrl.dispose();
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
    final title = _item.displayName;
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
                _reloadForCurrent();
              },
            ),
            const Divider(),
            _sidebarSectionLabel('フォルダ'),
            ListTile(
              title: Text(_folder?.raw ?? '未選択'),
              subtitle: const Text('表示するフォルダに切り替え'),
              trailing: const Icon(Icons.folder_open),
              onTap: () async {
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
                  _item.displayName,
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
                      reverse: true, // 右端（操作側）を見せやすくする
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
              tooltip: _isFavorite ? 'お気に入り解除' : 'お気に入り追加',
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
                  // 閲覧用タブのときだけページを移動
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
                    _popWithResult(); // Gridページへ戻る
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
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),

        // 端末タップでページ遷移（左=前 / 右=次）
        Positioned.fill(
          child: LayoutBuilder(
            builder: (context, c) {
              return GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTapUp: (details) {
                  // 閲覧用タブ以外は無視する
                  if (_tab.index != 0) return;

                  final dx = details.localPosition.dx;
                  final w = c.maxWidth;

                  // 中央は無反応に
                  final leftEdge = w * 0.35;
                  final rightEdge = w * 0.65;

                  if (dx < leftEdge) {
                    _prev(); // 左タップ → 前
                  } else if (dx > rightEdge) {
                    _next(); // 右タップ → 次
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
  }) {
    if (future == null) return const SizedBox.shrink();

    return FutureBuilder<Uint8List>(
      future: future,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        // 見開きは「縦合わせ」＋「綴じ側寄せ」が一番安定しやすかった
        final fit = isSpread ? BoxFit.fitHeight : _boxFit;

        //pdfの背景に白を追加（透明で透けて見える）
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
          // 下に表示するグリッドの高さ、画面35％ほどを参照
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
                        item.displayName,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                    if (_isPdf)
                      IconButton(
                        tooltip: 'PDF名を変更',
                        icon: const Icon(Icons.edit, color: Colors.white),
                        onPressed: _renameCurrentPdf,
                      ),
                  ],
                ),

                // Tags（タグ）
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
                            child: Text('作者'),
                          ),
                          DropdownMenuItem(
                            value: TagCategory.series,
                            child: Text('シリーズ'),
                          ),
                          DropdownMenuItem(
                            value: TagCategory.mediaType,
                            child: Text('形式(漫画/イラスト)'),
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
                          await _loadMasterTags(); // ★候補をカテゴリごとに更新
                        },
                      ),
                    );

                    final inputField = TextField(
                      controller: _tagCtrl,
                      decoration: const InputDecoration(
                        hintText: 'タグ（#不要 / 空白なし）',
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

                // --- Tags (カテゴリ候補) ---
                const SizedBox(height: 14),

                Row(
                  children: [
                    const Text('候補（このカテゴリ）'),
                    const SizedBox(width: 8),
                    if (_masterLoading)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    const Spacer(),
                    IconButton(
                      tooltip: '再読込',
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
                          const Text('候補がありません（追加するとここに蓄積されます）'),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                // --- PDFをスクロール内に固定高さで入れる ---
                if (_isPdf)
                  SizedBox(height: gridHeight, child: _buildPdfThumbGrid(item))
                else
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Center(
                      child: Text(
                        '画像はサムネ一覧なし',
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
          tooltip: '次',
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

        // 見開きはPDFだけ
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
              _twoPage ? '見開きON' : '見開きOFF',
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

        // Fit （全体を表示するモード）
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
              child: Text('全体表示(Contain)'),
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
            setState(() => _page = page);
            _leftFuture = _loadReaderBytes(item, _page);
            if (_twoPage) {
              final p2 = _page + 1;
              _rightFuture = (p2 <= _totalPages)
                  ? _loadReaderBytes(item, p2)
                  : null;
            }
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
