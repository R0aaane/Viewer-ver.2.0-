import 'dart:typed_data';
import 'package:flutter/material.dart';

import '../models/folder.dart';
import '../models/mediaItem.dart';
import '../repository/mediaRepository.dart';
import 'detailImage.dart';

enum _SortMode { name, updatedAt, addedAt }

class GalleryGridPage extends StatefulWidget {
  final MediaRepository repo;
  const GalleryGridPage({super.key, required this.repo});

  @override
  State<GalleryGridPage> createState() => _GalleryGridPageState();
}

class _GalleryGridPageState extends State<GalleryGridPage> {
  FolderHandle? _folder;
  List<MediaItem> _items = const [];
  bool _loading = false;

  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  // 並び替え（検索バー横のドロップダウン）
  _SortMode _sortMode = _SortMode.name;

  Future<void> _pickFolderAndLoad() async {
    final folder = await widget.repo.pickFolder();
    if (folder == null) return;

    setState(() {
      _folder = folder;
      _loading = true;
      _items = const [];
    });

    final items = await widget.repo.listMedia(folder);
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  DateTime _safeDateFromDynamic(dynamic v) {
    if (v == null) return DateTime.fromMillisecondsSinceEpoch(0);
    if (v is DateTime) return v;
    if (v is int) {
      // ms / sec どちらでもある程度耐える
      if (v < 2000000000) return DateTime.fromMillisecondsSinceEpoch(v * 1000);
      return DateTime.fromMillisecondsSinceEpoch(v);
    }
    if (v is String) {
      final parsed = DateTime.tryParse(v);
      return parsed ?? DateTime.fromMillisecondsSinceEpoch(0);
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  DateTime _getUpdatedAt(MediaItem item) {
    final o = item as dynamic;
    // できるだけ "それっぽい" フィールド名を拾う
    try {
      return _safeDateFromDynamic(o.updatedAt);
    } catch (_) {}
    try {
      return _safeDateFromDynamic(o.modifiedAt);
    } catch (_) {}
    try {
      return _safeDateFromDynamic(o.lastModified);
    } catch (_) {}
    try {
      return _safeDateFromDynamic(o.mtime);
    } catch (_) {}
    try {
      return _safeDateFromDynamic(o.dateModified);
    } catch (_) {}
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  DateTime _getAddedAt(MediaItem item) {
    final o = item as dynamic;
    try {
      return _safeDateFromDynamic(o.addedAt);
    } catch (_) {}
    try {
      return _safeDateFromDynamic(o.createdAt);
    } catch (_) {}
    try {
      return _safeDateFromDynamic(o.ctime);
    } catch (_) {}
    try {
      return _safeDateFromDynamic(o.dateAdded);
    } catch (_) {}
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  List<MediaItem> _applyFilter(
    List<MediaItem> input, {
    required bool? pdfOnly,
  }) {
    Iterable<MediaItem> out = input;

    // タブフィルタ: null=全て, true=PDFのみ, false=画像のみ
    if (pdfOnly != null) {
      if (pdfOnly) {
        out = out.where((e) => e.kind == MediaKind.pdf);
      } else {
        out = out.where((e) => e.kind != MediaKind.pdf);
      }
    }

    // 検索（作品名/タイトル）: displayName を部分一致
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      out = out.where((e) => e.displayName.toLowerCase().contains(q));
    }

    // 並び替え（既存フィルタ結果に sort を足すだけ）
    final list = out.toList(growable: true);
    switch (_sortMode) {
      case _SortMode.name:
        list.sort(
          (a, b) => a.displayName.toLowerCase().compareTo(
            b.displayName.toLowerCase(),
          ),
        );
        break;
      case _SortMode.updatedAt:
        // 新しい順
        list.sort((a, b) => _getUpdatedAt(b).compareTo(_getUpdatedAt(a)));
        break;
      case _SortMode.addedAt:
        // 新しい順
        list.sort((a, b) => _getAddedAt(b).compareTo(_getAddedAt(a)));
        break;
    }

    return list.toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            _folder == null ? '一覧表示' : '一覧表示: ${_folder!.raw}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            IconButton(
              tooltip: 'フォルダ選択',
              onPressed: _pickFolderAndLoad,
              icon: const Icon(Icons.folder_open),
            ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(112),
            child: Column(
              children: [
                // 検索バー（タイトル/作品名） + 並び替えドロップダウン
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _searchCtrl,
                          textInputAction: TextInputAction.search,
                          decoration: InputDecoration(
                            hintText: 'タイトルで検索',
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: _query.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: 'クリア',
                                    icon: const Icon(Icons.clear),
                                    onPressed: () {
                                      _searchCtrl.clear();
                                      setState(() => _query = '');
                                    },
                                  ),
                            border: const OutlineInputBorder(),
                            isDense: true,
                            filled: true,
                          ),
                          onChanged: (v) => setState(() => _query = v),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 140,
                        child: InputDecorator(
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<_SortMode>(
                              value: _sortMode,
                              isDense: true,
                              icon: const Icon(Icons.sort),
                              items: const [
                                DropdownMenuItem(
                                  value: _SortMode.name,
                                  child: Text('名前順'),
                                ),
                                DropdownMenuItem(
                                  value: _SortMode.updatedAt,
                                  child: Text('更新日時'),
                                ),
                                DropdownMenuItem(
                                  value: _SortMode.addedAt,
                                  child: Text('追加日時'),
                                ),
                              ],
                              onChanged: (v) {
                                if (v == null) return;
                                setState(() => _sortMode = v);
                              },
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // タブ
                const TabBar(
                  tabs: [
                    Tab(text: 'すべて'),
                    Tab(text: '画像'),
                    Tab(text: 'PDF'),
                  ],
                ),
              ],
            ),
          ),
        ),
        body: _folder == null
            ? Center(
                child: ElevatedButton(
                  onPressed: _pickFolderAndLoad,
                  child: const Text('フォルダ選択'),
                ),
              )
            : _loading
            ? const Center(child: CircularProgressIndicator())
            : _items.isEmpty
            ? const Center(child: Text('画像/PDFがありません'))
            : TabBarView(
                children: [
                  _buildGrid(_applyFilter(_items, pdfOnly: null)),
                  _buildGrid(_applyFilter(_items, pdfOnly: false)),
                  _buildGrid(_applyFilter(_items, pdfOnly: true)),
                ],
              ),
      ),
    );
  }

  Widget _buildGrid(List<MediaItem> items) {
    if (items.isEmpty) {
      return const Center(child: Text('該当するアイテムがありません'));
    }

    return GridView.builder(
      padding: const EdgeInsets.all(10),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 0.72, // 縦長の本っぽさ
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        return InkWell(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ImageDetailPage(
                  repo: widget.repo,
                  items: items,
                  initialIndex: i,
                ),
              ),
            );
          },
          child: _StackedThumbTile(repo: widget.repo, item: item),
        );
      },
    );
  }
}

class _StackedThumbTile extends StatelessWidget {
  final MediaRepository repo;
  final MediaItem item;
  const _StackedThumbTile({required this.repo, required this.item});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ThumbPair>(
      future: repo.readThumbPair(item, maxWidth: 360),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const _TileShell(loading: true);
        }
        if (!snap.hasData) {
          return const _TileShell(error: true);
        }

        final pair = snap.data!;
        final front = pair.front;
        final back = pair.back;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _BookStack(front: front, back: back),
            ),
            const SizedBox(height: 6),
            Text(
              item.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        );
      },
    );
  }
}

class _BookStack extends StatelessWidget {
  final Uint8List front;
  final Uint8List? back;
  const _BookStack({required this.front, this.back});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        if (back != null)
          Positioned(
            left: 10,
            top: 6,
            right: 0,
            bottom: 0,
            child: _ThumbCard(bytes: back!, elevation: 2, dim: true),
          ),
        Positioned(
          left: 0,
          top: 0,
          right: 10,
          bottom: 6,
          child: _ThumbCard(bytes: front, elevation: 6),
        ),
      ],
    );
  }
}

class _ThumbCard extends StatelessWidget {
  final Uint8List bytes;
  final double elevation;
  final bool dim;
  const _ThumbCard({required this.bytes, this.elevation = 4, this.dim = false});

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: elevation,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: ColorFiltered(
        colorFilter: dim
            ? const ColorFilter.matrix(<double>[
                0.85,
                0,
                0,
                0,
                0,
                0,
                0.85,
                0,
                0,
                0,
                0,
                0,
                0.85,
                0,
                0,
                0,
                0,
                0,
                1,
                0,
              ])
            : const ColorFilter.mode(Colors.transparent, BlendMode.dst),
        child: Image.memory(
          bytes,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          filterQuality: FilterQuality.low,
        ),
      ),
    );
  }
}

class _TileShell extends StatelessWidget {
  final bool loading;
  final bool error;
  const _TileShell({this.loading = false, this.error = false});

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(10),
      child: Center(
        child: loading
            ? const CircularProgressIndicator()
            : error
            ? const Icon(Icons.broken_image_outlined)
            : const SizedBox.shrink(),
      ),
    );
  }
}
