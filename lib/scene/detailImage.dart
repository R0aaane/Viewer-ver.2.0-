import 'dart:io';
import 'dart:typed_data';

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

  ReaderFitMode _fitMode = ReaderFitMode.vertical;

  Future<Uint8List>? _leftFuture;
  Future<Uint8List>? _rightFuture;

  final Map<int, Future<Uint8List>> _readerFutureCache = {};
  final Map<int, Future<Uint8List>> _thumbFutureCache = {};

  MediaItem get _item => _items[_index];
  bool get _isPdf => _item.kind == MediaKind.pdf;

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
      final dir = Directory(raw);
      if (await dir.exists()) {
        _folder = FolderHandle(raw);
      }
    }

    if (!mounted) return;
    setState(() {});
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

  Future<void> _saveLastFolder(FolderHandle folder) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_PrefsKeys.lastFolderRaw, folder.raw);
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
    return Scaffold(
      drawer: _buildSidebar(),
      backgroundColor: _uiBg,
      appBar: AppBar(
        backgroundColor: _uiBar,
        foregroundColor: Colors.white,
        title: Text(
          _item.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: _fullscreen ? 'フルスクリーン解除' : 'フルスクリーン',
            onPressed: _toggleFullscreen,
            icon: Icon(_fullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
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
      body: AnimatedBuilder(
        animation: _tab,
        builder: (context, _) {
          if (_tab.index == 0) return _buildReader();
          return _buildDetail();
        },
      ),
    );
  }

  Widget _buildReader() {
    return Focus(
      autofocus: true,
      onKeyEvent: (node, e) {
        if (e is! KeyDownEvent) return KeyEventResult.ignored;

        if (e.logicalKey == LogicalKeyboardKey.escape && _fullscreen) {
          _toggleFullscreen();
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
          _next();
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
          _prev();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Stack(
        children: [
          Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Expanded(child: _pageImage(_leftFuture)),
                if (_twoPage && _isPdf)
                  Expanded(child: _pageImage(_rightFuture)),
              ],
            ),
          ),
          Positioned(
            left: 12,
            right: 12,
            top: 12,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                _chipButton(icon: Icons.chevron_left, label: '前', onTap: _prev),
                _chipButton(
                  icon: Icons.chevron_right,
                  label: '次',
                  onTap: _next,
                ),
                if (_isPdf) _chipText('$_page / $_totalPages'),
                _chipButton(
                  icon: Icons.swap_horiz,
                  label: _twoPage ? '見開きON' : '見開きOFF',
                  onTap: () async {
                    final v = !_twoPage;
                    setState(() => _twoPage = v);
                    await _saveTwoPage(v);
                    _reloadForCurrent();
                  },
                ),
                _chipButton(
                  icon: Icons.aspect_ratio,
                  label: switch (_fitMode) {
                    ReaderFitMode.vertical => '縦',
                    ReaderFitMode.horizontal => '横',
                    ReaderFitMode.contain => '全体',
                  },
                  onTap: () async {
                    final next =
                        ReaderFitMode.values[(_fitMode.index + 1) %
                            ReaderFitMode.values.length];
                    setState(() => _fitMode = next);
                    await _saveFitMode(next);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _pageImage(Future<Uint8List>? future) {
    if (future == null) return const SizedBox.shrink();
    return FutureBuilder<Uint8List>(
      future: future,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return InteractiveViewer(
          minScale: 0.5,
          maxScale: 6,
          child: Image.memory(
            snap.data!,
            fit: _boxFit,
            gaplessPlayback: true,
            filterQuality: FilterQuality.high,
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

  Widget _chipText(String text) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _uiChip,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(text, style: const TextStyle(color: Colors.white)),
      ),
    );
  }

  Widget _chipButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _uiChip,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: Colors.white),
              const SizedBox(width: 6),
              Text(label, style: const TextStyle(color: Colors.white)),
            ],
          ),
        ),
      ),
    );
  }
}
