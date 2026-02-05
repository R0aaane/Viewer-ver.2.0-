import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/mediaItem.dart';
import '../repository/mediaRepository.dart';

/// 画像／PDFの表示フィット方式
/// vertical   : 高さ基準（縦読み向け）
/// horizontal : 幅基準（横長画像向け）
/// contain    : 全体収め
enum ReaderFitMode { vertical, horizontal, contain }

/// ===============================================
/// 画像・PDF 詳細閲覧ページ
/// - 画像：1枚表示
/// - PDF  ：単ページ／見開き表示対応
/// - キーボード／タップ操作対応
/// ===============================================
class ImageDetailPage extends StatefulWidget {
  final MediaRepository repo; // 画像・PDF読み込み用リポジトリ
  final List<MediaItem> items; // 表示対象のメディア一覧
  final int initialIndex; // 初期表示インデックス
  final int? initialPdfPage; // PDF初期ページ（画像の場合は無視）

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
  // 現在表示中の MediaItem インデックス
  late int _index;

  // ページ管理（PDFは複数、画像は常に1）
  int _page = 1; // 1-based
  int _totalPages = 1; // PDF: 総ページ数 / 画像: 1

  // 表示状態
  bool _twoPage = false; // PDF見開き表示フラグ
  bool _fullscreen = false;

  // 表示フィットモード
  ReaderFitMode _fitMode = ReaderFitMode.vertical;

  // 左右ページの描画データ（Futureで遅延ロード）
  Future<Uint8List>? _leftFuture;
  Future<Uint8List>? _rightFuture;

  /// 現在の MediaItem
  MediaItem get _item => widget.items[_index];

  /// PDFかどうか
  bool get _isPdf => _item.kind == MediaKind.pdf;

  // -----------------------------------------------
  // 初期化
  // -----------------------------------------------
  @override
  void initState() {
    super.initState();

    // 初期インデックス・ページ設定
    _index = widget.initialIndex;
    _page = widget.initialPdfPage ?? 1;

    // 現在アイテムを読み込み
    _reloadForCurrent();
  }

  // -----------------------------------------------
  // 終了処理（フルスクリーン解除）
  // -----------------------------------------------
  @override
  void dispose() {
    if (_fullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  // -----------------------------------------------
  // ReaderFitMode → BoxFit 変換
  // -----------------------------------------------
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

  // -----------------------------------------------
  // 指定ページの画像データを生成（PDF/画像共通）
  // -----------------------------------------------
  Future<Uint8List> _loadPageBytes(MediaItem item, int page) {
    // ★ PDFでも画像でも「page指定」でレンダリング
    return widget.repo.renderPageBytes(
      item,
      page,
      maxWidth: 1600, // 表示品質とパフォーマンスのバランス
    );
  }

  // -----------------------------------------------
  // 現在の MediaItem / ページに応じて再読み込み
  // -----------------------------------------------
  Future<void> _reloadForCurrent() async {
    final item = _item;

    // ★ 総ページ数取得（画像は1を返す想定）
    final total = await widget.repo.getPageCount(item);
    if (!mounted) return;

    setState(() {
      _totalPages = total;

      // 画像は常に page=1、PDFは範囲内に補正
      _page = _isPdf ? _page.clamp(1, _totalPages) : 1;

      // 左ページ
      _leftFuture = _loadPageBytes(item, _page);

      // 見開き時は右ページも生成
      if (_twoPage && _isPdf) {
        final next = _page + 1;
        _rightFuture = (next <= _totalPages)
            ? _loadPageBytes(item, next)
            : null;
      } else {
        _rightFuture = null;
      }
    });
  }

  // -----------------------------------------------
  // 次へ
  // - PDF : ページ送り
  // - 画像: 次アイテム
  // -----------------------------------------------
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

  // -----------------------------------------------
  // 前へ
  // -----------------------------------------------
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

  // -----------------------------------------------
  // 表示フィット切替
  // -----------------------------------------------
  void _setFit(ReaderFitMode mode) {
    setState(() => _fitMode = mode);
  }

  // -----------------------------------------------
  // フルスクリーン切替
  // -----------------------------------------------
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

  // -----------------------------------------------
  // 見開き切替（PDFのみ）
  // -----------------------------------------------
  void _toggleSpread() {
    if (!_isPdf) return;
    setState(() => _twoPage = !_twoPage);
    _reloadForCurrent();
  }

  // -----------------------------------------------
  // キーボード操作
  // ← / k : 前
  // → / j : 次
  // v     : 縦フィット
  // h     : 横フィット
  // f     : フルスクリーン
  // space : 見開き
  // -----------------------------------------------
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;

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

  // -----------------------------------------------
  // 上部ナビゲーションボタン共通UI
  // -----------------------------------------------
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

  // -----------------------------------------------
  // 上部バー（ページ操作・モード切替）
  // -----------------------------------------------
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

              // PDFのみページジャンプ
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

  // -----------------------------------------------
  // 単一ページ描画（拡大縮小対応）
  // -----------------------------------------------
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
          child: Image.memory(snap.data!, fit: _boxFit, gaplessPlayback: true),
        );
      },
    );
  }

  // -----------------------------------------------
  // メイン表示領域
  // - タップ左右で前後移動（モバイル）
  // -----------------------------------------------
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

  // -----------------------------------------------
  // 画面構築
  // -----------------------------------------------
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
