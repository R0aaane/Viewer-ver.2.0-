import 'dart:typed_data';
import 'package:flutter/material.dart';

import '../models/folder.dart';
import '../models/mediaItem.dart';
import '../repository/mediaRepository.dart';
import 'detailImage.dart';

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

    return out.toList(growable: false);
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
            preferredSize: const Size.fromHeight(104),
            child: Column(
              children: [
                // 検索バー（タイトル/作品名）
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
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
