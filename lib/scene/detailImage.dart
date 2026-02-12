import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/folder.dart';
import '../models/mediaItem.dart';
import '../repository/mediaRepository.dart';

enum ReaderFitMode { vertical, horizontal, contain }

class _PrefsKeys {
  static const String lastFolderRaw = 'prefs.lastFolderRaw';
  static const String fitMode =
      'prefs.readerFitMode'; // int (ReaderFitMode.index)
  static const String twoPage = 'prefs.readerTwoPage'; // bool

  static const String favorites = 'prefs.favorites'; // List<String>

  /// json map: { "<MediaItem.id>": ["tag1","tag2", ...] }
  static const String tagsJson = 'prefs.tagsJson';
}

class ImageDetailPage extends StatefulWidget {
  final MediaRepository repo;
  final List<MediaItem> items;
  final int initialIndex;
  final int? initialPdfPage;

  const ImageDetailPage({
    super.key,
    required this.repo,
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

  int _page = 1; // 1-based
  int _totalPages = 1; // PDF: pagesCount, 画像: 1

  bool _twoPage = false; // Full Spread
  bool _fullscreen = false;
  bool _inReader = true; // Tabが「閲覧」ならtrue

  bool _isFavorite = false;
  bool _favChanged = false;

  // tags
  Map<String, List<String>> _tagsById = <String, List<String>>{};
  bool _tagsChanged = false;

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

    // tags
    _tagsById = _decodeTags(prefs.getString(_PrefsKeys.tagsJson));

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

  List<String> _currentTags() => _tagsById[_item.id] ?? const <String>[];

  String? _normalizeTag(String input) {
    var t = input.trim();
    if (t.isEmpty) return null;
    if (t.startsWith('#')) t = t.substring(1);
    t = t.trim();
    if (t.isEmpty) return null;
    // 空白は不可（検索トークン崩れ防止）
    if (t.contains(RegExp(r'\s'))) return null;
    return t;
  }

  Future<void> _saveTagsToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_PrefsKeys.tagsJson, jsonEncode(_tagsById));
  }

  Future<void> _promptAddTag() async {
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('タグ追加'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(hintText: '例: tag（#不要 / 空白なし）'),
          autofocus: true,
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, ctrl.text),
            child: const Text('追加'),
          ),
        ],
      ),
    );

    if (result == null) return;
    final tag = _normalizeTag(result);
    if (tag == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('タグが無効です（空白なしで入力してください）')));
      return;
    }

    final tags = (_tagsById[_item.id] ?? <String>[]).toList(growable: true);
    if (!tags.any((e) => e.toLowerCase() == tag.toLowerCase())) {
      tags.add(tag);
      _tagsById[_item.id] = tags.toList(growable: false);
      await _saveTagsToPrefs();
      _tagsChanged = true;
      if (mounted) setState(() {});
    }
  }

  Future<void> _removeTag(String tag) async {
    final tags = (_tagsById[_item.id] ?? <String>[]).toList(growable: true);
    tags.removeWhere((e) => e.toLowerCase() == tag.toLowerCase());
    if (tags.isEmpty) {
      _tagsById.remove(_item.id);
    } else {
      _tagsById[_item.id] = tags.toList(growable: false);
    }
    await _saveTagsToPrefs();
    _tagsChanged = true;
    if (mounted) setState(() {});
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

  Future<void> _toggleFullscreen() async {
    setState(() => _fullscreen = !_fullscreen);
    if (_fullscreen) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
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
                _reloadForCurrent();
              },
            ),
            const Divider(),
            const ListTile(title: Text('フォルダ'), dense: true),
            ListTile(
              title: Text(_folder?.raw ?? '未選択'),
              subtitle: const Text('表示するフォルダに切り替え'),
              trailing: const Icon(Icons.folder_open),
              onTap: () async {
                Navigator.pop(context);

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
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        _popWithResult();
        return false;
      },
      child: Scaffold(
        drawer: _buildSidebar(),
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

          leadingWidth: 96,
          leading: Row(
            children: [
              IconButton(
                tooltip: '戻る',
                icon: const Icon(Icons.arrow_back),
                onPressed: _popWithResult,
              ),
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

        body: Shortcuts(
          shortcuts: const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.arrowLeft): _PrevIntent(),
            SingleActivator(LogicalKeyboardKey.arrowRight): _NextIntent(),
            SingleActivator(LogicalKeyboardKey.escape): _EscapeIntent(),
          },
          child: Actions(
            actions: <Type, Action<Intent>>{
              _PrevIntent: CallbackAction<_PrevIntent>(
                onInvoke: (intent) {
                  // 「閲覧」タブのときだけページ移動
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
                    _popWithResult(); // Gridへ戻る
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
        ),
      ),
    );
  }

  Widget _buildReader() {
    return Stack(
      children: [
        Center(
          child: LayoutBuilder(
            builder: (context, c) {
              const gap = 0.0; // gapは0でOK（真ん中余白は “寄せ” で消す）

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

        // ★見開きは「縦合わせ」＋「綴じ側寄せ」が一番安定しやすい
        final fit = isSpread ? BoxFit.fitHeight : _boxFit;

        return InteractiveViewer(
          minScale: 0.5,
          maxScale: 6,
          alignment: align, // ★重要：Viewer の基準点を綴じ側に寄せる
          child: Align(
            alignment: align, // ★重要：画像自体も綴じ側に寄せる
            child: Image.memory(
              snap.data!,
              fit: fit,
              alignment: align, // ★重要：Image の余白も綴じ側に寄せる
              gaplessPlayback: true,
              filterQuality: FilterQuality.high,
            ),
          ),
        );
      },
    );
  }

  Widget _buildDetail() {
    final item = _item;

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _infoRow('種別', item.kind == MediaKind.pdf ? 'PDF' : '画像'),
          const SizedBox(height: 8),
          if (_isPdf) _infoRow('ページ', '$_totalPages'),
          const SizedBox(height: 8),
          _infoRow('ID', item.id),
          // --- Tags ---
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final t in _currentTags())
                InputChip(
                  label: Text(
                    '#$t',
                    style: const TextStyle(color: Colors.white),
                  ),
                  backgroundColor: _uiChip,
                  deleteIconColor: Colors.white70,
                  onDeleted: () => _removeTag(t),
                ),
              ActionChip(
                label: const Text(
                  '+ タグ追加',
                  style: TextStyle(color: Colors.white),
                ),
                backgroundColor: _uiChip,
                onPressed: _promptAddTag,
              ),
            ],
          ),

          const SizedBox(height: 12),
          if (_isPdf)
            Expanded(child: _buildPdfThumbGrid(item))
          else
            Expanded(
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

        // Fit モード（メニュー）
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
