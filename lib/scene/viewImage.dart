import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/mediaItem.dart';
import '../repository/mediaRepository.dart';

class ImageViewerPage extends StatefulWidget {
  final MediaRepository repo;
  final List<MediaItem> items;
  final int initialIndex;
  final int? initialPdfPage;

  const ImageViewerPage({
    super.key,
    required this.repo,
    required this.items,
    required this.initialIndex,
    this.initialPdfPage,
  });

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  late int _index;

  int _page = 1;       // PDF: 1-based page, 画像: 常に1
  int _totalPages = 1; // PDF: pagesCount, 画像: 1

  Future<Uint8List>? _futureBytes;

  MediaItem get _item => widget.items[_index];
  bool get _isPdf => _item.kind == MediaKind.pdf;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _page = widget.initialPdfPage ?? 1;
    _loadCurrent();
  }

  Future<void> _loadCurrent() async {
    final item = _item;

    // 総ページ数取得（画像は1が返る想定）
    final total = await widget.repo.getPageCount(item);

    if (!mounted) return;

    setState(() {
      _totalPages = total;
      // 画像は常に page=1 にする（PDFから画像に切り替わっても安全）
      _page = _isPdf ? _page.clamp(1, _totalPages) : 1;

      _futureBytes = widget.repo.renderPageBytes(
        item,
        _page,
        maxWidth: 1600,
      );
    });
  }

  Future<void> _next() async {
    if (_isPdf) {
      if (_page < _totalPages) {
        _page++;
        await _loadCurrent();
      }
    } else {
      if (_index < widget.items.length - 1) {
        _index++;
        _page = 1;
        await _loadCurrent();
      }
    }
  }

  Future<void> _prev() async {
    if (_isPdf) {
      if (_page > 1) {
        _page--;
        await _loadCurrent();
      }
    } else {
      if (_index > 0) {
        _index--;
        _page = 1;
        await _loadCurrent();
      }
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    // Hitomi風: ←/k 前, →/j 次（好みで入替OK）
    if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
        event.logicalKey == LogicalKeyboardKey.keyJ) {
      _next();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
        event.logicalKey == LogicalKeyboardKey.keyK) {
      _prev();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isPdf ? 'PDF $_page / $_totalPages' : '画像'),
      ),
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: FutureBuilder<Uint8List>(
                  future: _futureBytes,
                  builder: (context, snap) {
                    if (snap.connectionState != ConnectionState.done) {
                      return const CircularProgressIndicator();
                    }
                    if (!snap.hasData) {
                      return const Icon(Icons.broken_image, size: 48);
                    }
                    return InteractiveViewer(
                      minScale: 1.0,
                      maxScale: 5.0,
                      child: Image.memory(
                        snap.data!,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                      ),
                    );
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  IconButton(
                    onPressed: (_isPdf ? _page > 1 : _index > 0) ? _prev : null,
                    icon: const Icon(Icons.chevron_left),
                    tooltip: '前へ',
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: (_isPdf
                            ? _page < _totalPages
                            : _index < widget.items.length - 1)
                        ? _next
                        : null,
                    icon: const Icon(Icons.chevron_right),
                    tooltip: '次へ',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
