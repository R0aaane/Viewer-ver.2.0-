import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/mediaItem.dart';
import '../repository/mediaRepository.dart';

/// ===============================================
/// ビューア画面（シンプル版）
/// - 画像：1枚表示（前後で別画像へ）
/// - PDF ：ページ表示（前後でページ送り）
/// - キーボード操作（←/→, k/j）
/// - ピンチ/ホイール想定の拡大縮小（InteractiveViewer）
///
/// ※ detailImage.dart が「機能多め」なら、こちらは「最小構成の閲覧」
/// ===============================================
class ImageViewerPage extends StatefulWidget {
  final MediaRepository repo; // 表示データ取得（画像読み込み / PDFレンダ）
  final List<MediaItem> items; // 連続閲覧対象
  final int initialIndex; // 初期表示アイテム
  final int? initialPdfPage; // PDFの場合の初期ページ（画像なら無視）

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
  // 現在表示中アイテムのインデックス
  late int _index;

  // ページ管理（PDF: 1-based、画像は常に 1）
  int _page = 1; // PDF: 1-based page, 画像: 常に1
  int _totalPages = 1; // PDF: pagesCount, 画像: 1

  // 表示する1ページ分のバイト列（画像 or PDFレンダ結果）
  Future<Uint8List>? _futureBytes;

  /// 現在の MediaItem
  MediaItem get _item => widget.items[_index];

  /// PDFかどうか
  bool get _isPdf => _item.kind == MediaKind.pdf;

  // -----------------------------------------------
  // 初期化
  // - 初期index/pageを受け取り、現在表示を読み込む
  // -----------------------------------------------
  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _page = widget.initialPdfPage ?? 1;
    _loadCurrent();
  }

  // -----------------------------------------------
  // 現在の「アイテム + ページ」を読み込み直す
  // 1) 総ページ数を取得（画像は1想定）
  // 2) pageを安全に補正（PDFのみ clamp / 画像は1固定）
  // 3) renderPageBytes() で表示用 bytes を取得
  // -----------------------------------------------
  Future<void> _loadCurrent() async {
    final item = _item;

    // ★ 総ページ数取得（画像は1が返る想定）
    final total = await widget.repo.getPageCount(item);

    if (!mounted) return;

    setState(() {
      _totalPages = total;

      // ★ 画像は常に page=1 に固定
      //   （PDF→画像へ切替時でも page が残って崩れないようにする）
      _page = _isPdf ? _page.clamp(1, _totalPages) : 1;

      // ★ 「今見せたいページ」をレンダリング（画像もPDFもここに集約）
      _futureBytes = widget.repo.renderPageBytes(
        item,
        _page,
        maxWidth: 1600, // 品質と速度のバランス（一覧より高め）
      );
    });
  }

  // -----------------------------------------------
  // 次へ
  // - PDF : 次ページ
  // - 画像: 次アイテム
  // -----------------------------------------------
  Future<void> _next() async {
    if (_isPdf) {
      if (_page < _totalPages) {
        _page++;
        await _loadCurrent();
      }
    } else {
      if (_index < widget.items.length - 1) {
        _index++;
        _page = 1; // 画像は常に1
        await _loadCurrent();
      }
    }
  }

  // -----------------------------------------------
  // 前へ
  // - PDF : 前ページ
  // - 画像: 前アイテム
  // -----------------------------------------------
  Future<void> _prev() async {
    if (_isPdf) {
      if (_page > 1) {
        _page--;
        await _loadCurrent();
      }
    } else {
      if (_index > 0) {
        _index--;
        _page = 1; // 画像は常に1
        await _loadCurrent();
      }
    }
  }

  // -----------------------------------------------
  // キーボード操作
  // - Hitomi風操作：
  //   → / j : 次
  //   ← / k : 前
  // -----------------------------------------------
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // ★ KeyDown だけ拾う（押しっぱなしの連打や KeyUp を避ける）
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

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

  // -----------------------------------------------
  // 画面構築
  // - AppBar: PDFなら「ページ/総数」を表示
  // - Body :
  //   - Focusでキーボード入力を受ける
  //   - FutureBuilderで bytes 読み込み状態に応じてUI切替
  //   - InteractiveViewerで拡大縮小＋パン
  // - Footer:
  //   - 前後ボタン（ページ/アイテムの境界で disable）
  // -----------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // ★ PDFは進捗が分かる表示、画像は固定表示
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
                    // ---------------------------------
                    // 読み込み中：スピナー
                    // ---------------------------------
                    if (snap.connectionState != ConnectionState.done) {
                      return const CircularProgressIndicator();
                    }

                    // ---------------------------------
                    // 失敗 or データ無し：壊れた画像表示
                    // ---------------------------------
                    if (!snap.hasData) {
                      return const Icon(Icons.broken_image, size: 48);
                    }

                    // ---------------------------------
                    // 成功：表示
                    // - contain で画面内に収める（最小構成）
                    // - InteractiveViewer で拡大縮小
                    // ---------------------------------
                    return InteractiveViewer(
                      minScale: 1.0,
                      maxScale: 5.0,
                      child: Image.memory(
                        snap.data!,
                        fit: BoxFit.contain,
                        gaplessPlayback: true, // ページ切替時のちらつき軽減
                      ),
                    );
                  },
                ),
              ),
            ),

            // -----------------------------------------
            // 下部操作バー（前後ボタンのみ）
            // - 境界判定：押せる時だけ onPressed を渡す
            // -----------------------------------------
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
                    onPressed:
                        (_isPdf
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
