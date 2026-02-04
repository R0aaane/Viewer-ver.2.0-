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

class _ImageDetailPageState extends State<ImageDetailPage> {
  late int _index;

  int _page = 1;        // 1-based
  int _totalPages = 1;  // PDF: pagesCount, 画像: 1

  bool _twoPage = false; // Full Spread
  bool _fullscreen = false;

  ReaderFitMode _fitMode = ReaderFitMode.vertical;

  Future<Uint8List>? _leftFuture;
  Future<Uint8List>? _rightFuture;

  MediaItem get _item => widget.items[_index];
  bool get _isPdf => _item.kind == MediaKind.pdf;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _page = widget.initialPdfPage ?? 1;
    _reloadForCurrent();
  }

  @override
  void dispose() {
    if (_fullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
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

  Future<Uint8List> _loadPageBytes(MediaItem item, int page) {
    // ★ここが重要：PDFも含め「page指定で描画」する
    return widget.repo.renderPageBytes(item, page, maxWidth: 1600);
  }

  Future<void> _reloadForCurrent() async {
    final item = _item;

    // ★総ページ数を取得（画像は1が返る想定）
    final total = await widget.repo.getPageCount(item);

    if (!mounted) return;

    setState(() {
      _totalPages = total;

      // 画像は常に page=1、PDFは範囲内に丸める
      _page = _isPdf ? _page.clamp(1, _totalPages) : 1;

      _leftFuture = _loadPageBytes(item, _page);

      if (_twoPage && _isPdf) {
        final next = _page + 1;
        _rightFuture = (next <= _totalPages) ? _loadPageBytes(item, next) : null;
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
        _page = next;
        _reloadForCurrent();
      }
    } else {
      if (_index < widget.items.length - 1) {
        _index++;
        _page = 1;
        _reloadForCurrent();
      }
    }
  }

  void _prev() {
    if (_isPdf) {
      final step = _twoPage ? 2 : 1;
      final prev = _page - step;
      if (prev >= 1) {
        _page = prev;
        _reloadForCurrent();
      }
    } else {
      if (_index > 0) {
        _index--;
        _page = 1;
        _reloadForCurrent();
      }
    }
  }

  void _setFit(ReaderFitMode mode) {
    setState(() => _fitMode = mode);
  }

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
    if (!_isPdf) return; // 画像は見開き不要
    setState(() => _twoPage = !_twoPage);
    _reloadForCurrent();
  }

  // キーボード：←/k 前、→/j 次（Hitomi風）
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.keyJ) {
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
      label: Text(label, style: TextStyle(color: active ? Colors.white : Colors.white38)),
    );
  }

  Widget _buildTopBar() {
    final pageItems = List<int>.generate(_totalPages, (i) => i + 1);

    return Material(
      color: const Color(0xFF1F1F1F),
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
                active: _isPdf ? (_page < _totalPages) : (_index < widget.items.length - 1),
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
                      color: const Color(0xFF2B2B2B),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<int>(
                        value: _page,
                        dropdownColor: const Color(0xFF2B2B2B),
                        iconEnabledColor: Colors.white,
                        items: pageItems
                            .map((p) => DropdownMenuItem(
                                  value: p,
                                  child: Text('Page $p', style: const TextStyle(color: Colors.white)),
                                ))
                            .toList(),
                        onChanged: (p) {
                          if (p == null) return;
                          _page = p;
                          _reloadForCurrent();
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
          maxScale: 5.0,
          child: Image.memory(
            snap.data!,
            fit: _boxFit,
            gaplessPlayback: true,
          ),
        );
      },
    );
  }

  Widget _buildBody() {
    // Future がセットされてない（初回ロード中）
    if (_leftFuture == null) {
    return const Center(child: CircularProgressIndicator());
  }

    // 左右タップで前後（モバイル用）
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
        color: Colors.black,
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: Column(
          children: [
            if (!_fullscreen) _buildTopBar(),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }
}
