import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/mediaItem.dart';
import '../repository/mediaRepository.dart';

enum ReaderFitMode { vertical, horizontal, contain }

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
  // ----------------
  // state
  late int _index;

  late final TabController _tab;

  int _page = 1; // 1-based
  int _totalPages = 1; // PDF: pagesCount, 画像: 1

  bool _twoPage = false; // Full Spread
  bool _fullscreen = false;

  ReaderFitMode _fitMode = ReaderFitMode.vertical;

  Future<Uint8List>? _leftFuture;
  Future<Uint8List>? _rightFuture;

  // ★フリーズ対策：同じページの再レンダリングを避けるキャッシュ
  final Map<int, Future<Uint8List>> _readerFutureCache = {};
  final Map<int, Future<Uint8List>> _thumbFutureCache = {};

  MediaItem get _item => widget.items[_index];
  bool get _isPdf => _item.kind == MediaKind.pdf;

  // ----------------
  // theme (HTMLっぽい黒基調)
  static const _uiBg = Color(0xFF0F0F10);
  static const _uiBar = Color(0xFF1F1F1F);
  static const _uiChip = Color(0xFF2B2B2B);

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _page = widget.initialPdfPage ?? 1;

    _tab = TabController(length: 2, vsync: this);
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

  // ----------------
  // helpers
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
    // 閲覧用：高解像度
    return _readerFutureCache.putIfAbsent(page, () {
      return widget.repo.renderPageBytes(item, page, maxWidth: 1600);
    });
  }

  Future<Uint8List> _loadThumbBytes(MediaItem item, int page) {
    // ★サムネ用：低解像度（フリーズ最大要因を潰す）
    return _thumbFutureCache.putIfAbsent(page, () {
      return widget.repo.renderPageBytes(item, page, maxWidth: 320);
    });
  }

  Future<void> _reloadForCurrent() async {
    final item = _item;

    // ★アイテムが変わったらキャッシュをクリア（別PDFのページが混ざるのを防ぐ）
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
      if (_index < widget.items.length - 1) {
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

  void _setFit(ReaderFitMode mode) => setState(() => _fitMode = mode);

  Future<void> _toggleFullscreen() async {
    _fullscreen = !_fullscreen;
    if (_fullscreen) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    if (!mounted) return;
    setState(() {});
  }

  void _toggleSpread() {
    if (!_isPdf) return;
    setState(() => _twoPage = !_twoPage);
    // 見開きの有無で右ページfutureを更新
    _leftFuture = _loadReaderBytes(_item, _page);
    if (_twoPage) {
      final p2 = _page + 1;
      _rightFuture = (p2 <= _totalPages) ? _loadReaderBytes(_item, p2) : null;
    } else {
      _rightFuture = null;
    }
  }

  // キーボード：←/k 前、→/j 次
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;

    // ESCでフルスクリーン解除
    if (key == LogicalKeyboardKey.escape) {
      if (_fullscreen) {
        _toggleFullscreen();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.keyJ) {
      _next();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.keyK) {
      _prev();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyV) {
      _setFit(ReaderFitMode.vertical);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyH) {
      _setFit(ReaderFitMode.horizontal);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyC) {
      _setFit(ReaderFitMode.contain);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF) {
      _toggleFullscreen();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.space) {
      _toggleSpread();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _navButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    bool active = true,
  }) {
    return TextButton.icon(
      onPressed: active ? onPressed : null,
      icon: Icon(icon, color: active ? Colors.white : Colors.white38),
      label: Text(
        label,
        style: TextStyle(color: active ? Colors.white : Colors.white38),
      ),
    );
  }

  Widget _buildTopBar() {
    final pageItems = List<int>.generate(_totalPages, (i) => i + 1);

    return Material(
      color: _uiBar,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              const SizedBox(width: 8),
              _navButton(
                icon: Icons.chevron_left,
                label: 'Prev',
                onPressed: _prev,
                active: _isPdf ? (_page > 1) : (_index > 0),
              ),
              _navButton(
                icon: Icons.chevron_right,
                label: 'Next',
                onPressed: _next,
                active: _isPdf
                    ? (_page < _totalPages)
                    : (_index < widget.items.length - 1),
              ),
              const SizedBox(width: 12),
              _navButton(
                icon: Icons.height,
                label: 'Fit V',
                onPressed: () => _setFit(ReaderFitMode.vertical),
              ),
              _navButton(
                icon: Icons.width_normal,
                label: 'Fit H',
                onPressed: () => _setFit(ReaderFitMode.horizontal),
              ),
              _navButton(
                icon: Icons.crop_free,
                label: 'Contain',
                onPressed: () => _setFit(ReaderFitMode.contain),
              ),
              _navButton(
                icon: _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                label: 'Full',
                onPressed: _toggleFullscreen,
              ),
              _navButton(
                icon: _twoPage ? Icons.pause : Icons.stop,
                label: _twoPage ? 'Spread' : 'Single',
                onPressed: _toggleSpread,
                active: _isPdf,
              ),
              const Spacer(),
              if (_isPdf)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: _uiChip,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<int>(
                        value: _page,
                        dropdownColor: _uiChip,
                        iconEnabledColor: Colors.white,
                        items: pageItems
                            .map(
                              (p) => DropdownMenuItem(
                                value: p,
                                child: Text(
                                  'Page $p',
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (p) {
                          if (p == null) return;
                          setState(() => _page = p);
                          _leftFuture = _loadReaderBytes(_item, _page);
                          if (_twoPage) {
                            final p2 = _page + 1;
                            _rightFuture = (p2 <= _totalPages)
                                ? _loadReaderBytes(_item, p2)
                                : null;
                          } else {
                            _rightFuture = null;
                          }
                        },
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImagePane(Future<Uint8List> future) {
    return FutureBuilder<Uint8List>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (!snap.hasData) {
          return const Center(child: Icon(Icons.broken_image, size: 48));
        }
        return InteractiveViewer(
          minScale: 1.0,
          maxScale: 6.0,
          child: Image.memory(snap.data!, fit: _boxFit, gaplessPlayback: true),
        );
      },
    );
  }

  Widget _buildBody() {
    if (_leftFuture == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (d) {
        final w = MediaQuery.of(context).size.width;
        if (d.localPosition.dx < w * 0.5) {
          _prev();
        } else {
          _next();
        }
      },
      child: Container(
        color: _uiBg,
        child: Center(
          child: _twoPage && _isPdf
              ? Row(
                  children: [
                    Expanded(child: _buildImagePane(_leftFuture!)),
                    Expanded(
                      child: _rightFuture == null
                          ? const SizedBox.shrink()
                          : _buildImagePane(_rightFuture!),
                    ),
                  ],
                )
              : _buildImagePane(_leftFuture!),
        ),
      ),
    );
  }

  Widget _infoChip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: _uiChip,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white, fontSize: 12),
      ),
    );
  }

  Widget _buildDetailsTab() {
    final item = _item;

    return FutureBuilder<int>(
      future: widget.repo.getPageCount(item),
      builder: (context, snap) {
        final total = snap.data ?? 1;

        final w = MediaQuery.of(context).size.width;
        // 画面幅で列数を調整（PCで増える / モバイルで減る）
        final crossAxisCount = w >= 1200
            ? 10
            : w >= 900
            ? 8
            : w >= 600
            ? 6
            : 3;

        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // カバー（軽いサムネ）
                        SizedBox(
                          width: 170,
                          child: AspectRatio(
                            aspectRatio: 0.72,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: FutureBuilder<Uint8List>(
                                future: _loadThumbBytes(item, 1),
                                builder: (context, s) {
                                  if (s.connectionState !=
                                      ConnectionState.done) {
                                    return Container(
                                      color: _uiChip,
                                      child: const Center(
                                        child: CircularProgressIndicator(),
                                      ),
                                    );
                                  }
                                  if (!s.hasData) {
                                    return Container(
                                      color: _uiChip,
                                      child: const Center(
                                        child: Icon(Icons.broken_image),
                                      ),
                                    );
                                  }
                                  return Image.memory(
                                    s.data!,
                                    fit: BoxFit.cover,
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),

                        // 情報
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.displayName,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleLarge
                                    ?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white,
                                    ),
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  _infoChip(_isPdf ? 'PDF' : 'IMAGE'),
                                  _infoChip('Pages: $total'),
                                ],
                              ),
                              const SizedBox(height: 12),
                              FilledButton.icon(
                                onPressed: () {
                                  setState(() => _page = 1);
                                  _leftFuture = _loadReaderBytes(item, _page);
                                  if (_twoPage && _isPdf) {
                                    final p2 = _page + 1;
                                    _rightFuture = (p2 <= _totalPages)
                                        ? _loadReaderBytes(item, p2)
                                        : null;
                                  } else {
                                    _rightFuture = null;
                                  }
                                  _tab.animateTo(0);
                                },
                                icon: const Icon(Icons.chrome_reader_mode),
                                label: const Text('閲覧する'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    const Divider(height: 1, color: Colors.white12),
                    const SizedBox(height: 10),
                    Text(
                      'サムネイル',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),

            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                  childAspectRatio: 0.72,
                ),
                delegate: SliverChildBuilderDelegate((context, i) {
                  final page = i + 1;
                  return _ThumbCell(
                    futureBytes: _loadThumbBytes(item, page),
                    label: '$page',
                    selected: page == _page,
                    onTap: () {
                      setState(() => _page = page);
                      _leftFuture = _loadReaderBytes(item, _page);
                      if (_twoPage && _isPdf) {
                        final p2 = _page + 1;
                        _rightFuture = (p2 <= _totalPages)
                            ? _loadReaderBytes(item, p2)
                            : null;
                      } else {
                        _rightFuture = null;
                      }
                      _tab.animateTo(0);
                    },
                  );
                }, childCount: total),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // フルスクリーン時は「閲覧のみ」
    if (_fullscreen) {
      return PopScope(
        canPop: false,
        onPopInvoked: (didPop) {
          if (_fullscreen) _toggleFullscreen();
        },
        child: Scaffold(
          body: Focus(autofocus: true, onKeyEvent: _onKey, child: _buildBody()),
        ),
      );
    }

    return Scaffold(
      backgroundColor: _uiBg,
      appBar: AppBar(
        backgroundColor: _uiBar,
        foregroundColor: Colors.white,
        title: Text(
          _item.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(text: '閲覧'),
            Tab(text: '詳細'),
          ],
        ),
      ),

      // ★ここがフリーズ対策の核：TabBarViewを使わず「選択タブだけ build」
      body: AnimatedBuilder(
        animation: _tab,
        builder: (context, _) {
          if (_tab.index == 0) {
            return Focus(
              autofocus: true,
              onKeyEvent: _onKey,
              child: Column(
                children: [
                  _buildTopBar(),
                  Expanded(child: _buildBody()),
                ],
              ),
            );
          }
          return _buildDetailsTab();
        },
      ),
    );
  }
}

class _ThumbCell extends StatelessWidget {
  final Future<Uint8List> futureBytes;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ThumbCell({
    required this.futureBytes,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? Colors.white : Colors.white24,
            width: selected ? 2 : 1,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: Stack(
            fit: StackFit.expand,
            children: [
              FutureBuilder<Uint8List>(
                future: futureBytes,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const ColoredBox(
                      color: Color(0xFF2B2B2B),
                      child: Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(),
                        ),
                      ),
                    );
                  }
                  if (!snap.hasData) {
                    return const ColoredBox(
                      color: Color(0xFF2B2B2B),
                      child: Center(
                        child: Icon(Icons.broken_image, color: Colors.white70),
                      ),
                    );
                  }
                  return Image.memory(
                    snap.data!,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  );
                },
              ),
              Align(
                alignment: Alignment.bottomRight,
                child: Container(
                  margin: const EdgeInsets.all(4),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.55),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    label,
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
