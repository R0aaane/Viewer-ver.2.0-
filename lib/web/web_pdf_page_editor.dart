import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/pdf_page_edit.dart';

class WebPdfPageEditor extends StatefulWidget {
  final PdfPageEditorClient client;
  final String mediaId;
  final String title;
  final int initialPage;

  const WebPdfPageEditor({
    super.key,
    required this.client,
    required this.mediaId,
    required this.title,
    this.initialPage = 1,
  });

  @override
  State<WebPdfPageEditor> createState() => _WebPdfPageEditorState();
}

class _PageEdit {
  final int originalPage;
  int rotation = 0;
  _PageEdit(this.originalPage);
}

class _WebPdfPageEditorState extends State<WebPdfPageEditor> {
  final _scroll = ScrollController();
  final _jump = TextEditingController();
  final _thumbnails = <int, Future<Uint8List>>{};
  List<_PageEdit> _pages = [];
  List<Map<String, dynamic>> _backups = [];
  String _revision = '';
  int _originalCount = 0;
  bool _busy = true;
  String? _error;

  bool get _dirty =>
      _pages.length != _originalCount ||
      _pages.indexed.any(
        (item) => item.$2.originalPage != item.$1 + 1 || item.$2.rotation != 0,
      );

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _jump.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final info = await widget.client.fetchPdfEditInfo(widget.mediaId);
      if (!mounted) return;
      setState(() {
        _revision = info['revision'] as String;
        _originalCount = (info['pageCount'] as num).toInt();
        _pages = List.generate(_originalCount, (index) => _PageEdit(index + 1));
        _backups = (info['backups'] as List)
            .map((item) => Map<String, dynamic>.from(item as Map))
            .toList();
        _thumbnails.clear();
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(
            ((widget.initialPage - 1).clamp(0, _pages.length - 1) * 132.0)
                .clamp(0, _scroll.position.maxScrollExtent),
          );
        }
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String message) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('キャンセル'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('実行'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _save() async {
    final deleted = _originalCount - _pages.length;
    final rotated = _pages.where((page) => page.rotation != 0).length;
    if (!await _confirm(
      'PDFの編集を保存',
      '削除: $deletedページ、回転: $rotatedページ\n表示中の順番で元PDFに保存します。保存前のPDFは自動バックアップされ、履歴から復元できます。',
    )) {
      return;
    }
    if (!mounted) return;
    await _apply(
      () => widget.client.savePdfPages(
        widget.mediaId,
        _revision,
        _pages
            .map(
              (page) => {'page': page.originalPage, 'rotation': page.rotation},
            )
            .toList(),
      ),
    );
  }

  Future<void> _restore(Map<String, dynamic> backup) async {
    if (!await _confirm(
      'PDFをバックアップから復元',
      '${backup['createdAt']} のPDF（${backup['pageCount']}ページ）に戻します。未保存の編集は破棄されます。現在のPDFもバックアップします。',
    )) {
      return;
    }
    if (!mounted) return;
    await _apply(
      () => widget.client.restorePdfBackup(
        widget.mediaId,
        _revision,
        backup['id'] as String,
      ),
    );
  }

  Future<void> _apply(Future<Map<String, dynamic>> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _move(int from, int to) {
    if (_busy || to < 0 || to >= _pages.length) return;
    setState(() => _pages.insert(to, _pages.removeAt(from)));
  }

  Future<void> _close() async {
    if (_dirty && !await _confirm('編集を破棄', '保存せずに閉じますか？')) return;
    if (mounted) Navigator.pop(context, false);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      child: PopScope(
        canPop: !_busy,
        child: Scaffold(
          appBar: AppBar(
            leading: IconButton(
              onPressed: _busy ? null : _close,
              icon: const Icon(Icons.close),
            ),
            title: Text('PDFページ編集: ${widget.title}'),
            actions: [
              if (_backups.isNotEmpty)
                PopupMenuButton<int>(
                  enabled: !_busy,
                  tooltip: 'バックアップから復元',
                  icon: const Icon(Icons.restore),
                  onSelected: (index) => _restore(_backups[index]),
                  itemBuilder: (context) => _backups.indexed
                      .map(
                        (entry) => PopupMenuItem(
                          value: entry.$1,
                          child: Text(
                            '${DateTime.tryParse(entry.$2['createdAt'] as String)?.toLocal() ?? entry.$2['createdAt']} (${entry.$2['pageCount']}ページ)',
                          ),
                        ),
                      )
                      .toList(),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: FilledButton.icon(
                  onPressed: _busy || !_dirty || _pages.isEmpty ? null : _save,
                  icon: const Icon(Icons.save),
                  label: const Text('保存'),
                ),
              ),
            ],
          ),
          body: Column(
            children: [
              if (_busy) const LinearProgressIndicator(),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('残り ${_pages.length} / 元 $_originalCount ページ'),
                    const Text('ドラッグまたは上下ボタンで並べ替え'),
                    SizedBox(
                      width: 150,
                      child: TextField(
                        controller: _jump,
                        enabled: !_busy,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '元のページ番号へ移動',
                          isDense: true,
                        ),
                        onSubmitted: (value) {
                          final index = _pages.indexWhere(
                            (page) => page.originalPage == int.tryParse(value),
                          );
                          if (index >= 0 && _scroll.hasClients) {
                            _scroll.animateTo(
                              (index * 132.0).clamp(
                                0,
                                _scroll.position.maxScrollExtent,
                              ),
                              duration: const Duration(milliseconds: 200),
                              curve: Curves.easeOut,
                            );
                          }
                        },
                      ),
                    ),
                    TextButton(
                      onPressed: _busy || !_dirty
                          ? null
                          : () => setState(
                              () => _pages = List.generate(
                                _originalCount,
                                (i) => _PageEdit(i + 1),
                              ),
                            ),
                      child: const Text('編集をリセット'),
                    ),
                  ],
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                      TextButton(
                        onPressed: _busy ? null : _load,
                        child: const Text('変更を破棄して再読み込み'),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: ReorderableListView.builder(
                  scrollController: _scroll,
                  itemExtent: 132,
                  buildDefaultDragHandles: false,
                  itemCount: _pages.length,
                  onReorder: (from, to) {
                    if (to > from) to--;
                    _move(from, to);
                  },
                  itemBuilder: (context, index) {
                    final page = _pages[index];
                    final future = _thumbnails.putIfAbsent(
                      page.originalPage,
                      () => widget.client.fetchThumbnail(
                        widget.mediaId,
                        width: 120,
                        height: 160,
                        page: page.originalPage,
                      ),
                    );
                    return Card(
                      key: ValueKey(page.originalPage),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 76,
                              height: 100,
                              child: FutureBuilder<Uint8List>(
                                future: future,
                                builder: (context, snapshot) {
                                  if (snapshot.hasError) {
                                    return const Icon(
                                      Icons.broken_image_outlined,
                                    );
                                  }
                                  if (!snapshot.hasData) {
                                    return const Center(
                                      child: CircularProgressIndicator(),
                                    );
                                  }
                                  return RotatedBox(
                                    quarterTurns: page.rotation ~/ 90,
                                    child: Image.memory(
                                      snapshot.data!,
                                      fit: BoxFit.contain,
                                    ),
                                  );
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '${index + 1}ページ目\n元: ${page.originalPage}ページ\n回転: ${page.rotation}°',
                                maxLines: 4,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            SizedBox(
                              width: MediaQuery.sizeOf(context).width < 600
                                  ? 128
                                  : 224,
                              child: IconButtonTheme(
                                data: const IconButtonThemeData(
                                  style: ButtonStyle(
                                    visualDensity: VisualDensity.compact,
                                  ),
                                ),
                                child: Wrap(
                                  children: [
                                    IconButton(
                                      tooltip: '90度右回転',
                                      onPressed: _busy
                                          ? null
                                          : () => setState(
                                              () => page.rotation =
                                                  (page.rotation + 90) % 360,
                                            ),
                                      icon: const Icon(Icons.rotate_right),
                                    ),
                                    IconButton(
                                      tooltip: '前へ移動',
                                      onPressed: _busy || index == 0
                                          ? null
                                          : () => _move(index, index - 1),
                                      icon: const Icon(Icons.arrow_upward),
                                    ),
                                    IconButton(
                                      tooltip: '後ろへ移動',
                                      onPressed:
                                          _busy || index == _pages.length - 1
                                          ? null
                                          : () => _move(index, index + 1),
                                      icon: const Icon(Icons.arrow_downward),
                                    ),
                                    IconButton(
                                      tooltip: 'このページを削除',
                                      onPressed: _busy || _pages.length <= 1
                                          ? null
                                          : () => setState(
                                              () => _pages.removeAt(index),
                                            ),
                                      icon: const Icon(Icons.delete_outline),
                                    ),
                                    ReorderableDragStartListener(
                                      index: index,
                                      enabled: !_busy,
                                      child: const Padding(
                                        padding: EdgeInsets.all(8),
                                        child: Icon(Icons.drag_handle),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
