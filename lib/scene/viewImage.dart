import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfx/pdfx.dart';

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

  PdfController? _pdfController;
  int? _pdfTotalPages; // ★総ページ

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _setupPdfIfNeeded();
  }

  @override
  void dispose() {
    _pdfController?.dispose();
    super.dispose();
  }

  Future<void> _setupPdfIfNeeded() async {
    _pdfController?.dispose();
    _pdfController = null;
    _pdfTotalPages = null;

    final item = widget.items[_index];
    if (item.kind != MediaKind.pdf) {
      if (mounted) setState(() {});
      return;
    }

    final controller = PdfController(
      document: PdfDocument.openFile(item.id), // Future<PdfDocument>
    );

    final p = widget.initialPdfPage;
    if (p != null && p >= 1) {
      // controllerが ready になる前に呼んでも効く版/効かない版があるので
     // 念のため microtask で一段遅らせる
      Future.microtask(() {
        controller.jumpToPage(p);
      });
    }
    // ★総ページ数を取得
    // pdfxでは controller.document（Future<PdfDocument>）が取れる版があります。
    // 取れない版の場合は下の fallback を使ってください。
    try {
      final doc = await controller.document;
      final total = doc.pagesCount;
      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() {
        _pdfController = controller;
        _pdfTotalPages = total;
      });
    } catch (_) {
      // fallback: 別でopenして総ページ取得（最短で確実）
      final doc = await PdfDocument.openFile(item.id);
      final total = doc.pagesCount;
      await doc.close();

      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() {
        _pdfController = controller;
        _pdfTotalPages = total;
      });
    }
  }

  void _handleKey(KeyEvent e) {
    if (e is! KeyDownEvent) return;
    final item = widget.items[_index];

    if (item.kind == MediaKind.pdf && _pdfController != null) {
      if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
        _pdfController!.nextPage(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
        );
      } else if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
        _pdfController!.previousPage(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.items[_index];

    return Scaffold(
      backgroundColor: Colors.black, // ★背景黒
      appBar: AppBar(
        title: const Text('拡大表示'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Focus(
        autofocus: true,
        onKeyEvent: (_, e) {
          _handleKey(e);
          return KeyEventResult.handled;
        },
        child: Stack(
          children: [
            Positioned.fill(
              child: item.kind == MediaKind.pdf
                  ? _buildPdfViewer()
                  : _buildImageViewer(),
            ),

            // ★ページ数表示（右下）
            Positioned(
              right: 12,
              bottom: 12,
              child: item.kind == MediaKind.pdf
                  ? _PdfPageCounter(controller: _pdfController, total: _pdfTotalPages)
                  : _SimpleCounter(text: '${_index + 1} / ${widget.items.length}'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPdfViewer() {
  final c = _pdfController;
  if (c == null) {
    return const Center(child: CircularProgressIndicator());
  }

  return Stack(
    children: [
      Positioned.fill(
        child: PdfView(controller: c),
      ),

      // ★PDFページ（画像）の上にページ数を重ねる
      Positioned(
        top: 12,
        left: 0,
        right: 0,
        child: Align(
          alignment: Alignment.topCenter,
        child: IgnorePointer(
          ignoring: true, // ←タップ/スワイプを邪魔しない
          child: _PdfPageCounter(controller: c, total: _pdfTotalPages),
        ),
        ),
      ),
      ],
    );
  }

  Widget _buildImageViewer() {
    return PhotoViewGallery.builder(
      itemCount: widget.items.length,
      pageController: PageController(initialPage: _index),
      onPageChanged: (i) async {
        setState(() => _index = i);
        await _setupPdfIfNeeded();
      },
      backgroundDecoration: const BoxDecoration(color: Colors.black), // ★黒
      builder: (context, index) {
        final it = widget.items[index];
        if (it.kind == MediaKind.pdf) {
          return PhotoViewGalleryPageOptions.customChild(
            child: const Center(
              child: Text('PDFはPDFビューで表示します', style: TextStyle(color: Colors.white)),
            ),
          );
        }

        return PhotoViewGalleryPageOptions.customChild(
          child: FutureBuilder<Uint8List>(
            future: widget.repo.readBytes(it),
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              return Image.memory(snap.data!, fit: BoxFit.contain);
            },
          ),
          minScale: PhotoViewComputedScale.contained,
          maxScale: PhotoViewComputedScale.covered * 3.0,
        );
      },
    );
  }
}

class _SimpleCounter extends StatelessWidget {
  final String text;
  const _SimpleCounter({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.65),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 13)),
    );
  }
}

class _PdfPageCounter extends StatelessWidget {
  final PdfController? controller;
  final int? total;
  const _PdfPageCounter({required this.controller, required this.total});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (c == null) return const _SimpleCounter(text: '...');

    // pdfxには pageListenable がある版が多い
    return ValueListenableBuilder<int>(
      valueListenable: c.pageListenable,
      builder: (context, page, _) {
        final t = total;
        final txt = (t == null) ? '$page / ?' : '$page / $t';
        return _SimpleCounter(text: txt);
      },
    );
  }
}