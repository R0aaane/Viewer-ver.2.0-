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
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_folder == null ? '一覧表示' : '一覧表示: ${_folder!.raw}',
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'フォルダ選択',
            onPressed: _pickFolderAndLoad,
            icon: const Icon(Icons.folder_open),
          ),
        ],
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
                  : GridView.builder(
                      padding: const EdgeInsets.all(10),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 4,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 10,
                        childAspectRatio: 0.72, // 縦長の本っぽさ
                      ),
                      itemCount: _items.length,
                      itemBuilder: (context, i) {
                        final item = _items[i];
                        return InkWell(
                          onTap: () {
                            Navigator.push(context, MaterialPageRoute(
                              builder: (_) => ImageDetailPage(
                                repo: widget.repo,
                                items: _items,
                                initialIndex: i,
                              ),
                            ));
                          },
                          child: _StackedThumbTile(repo: widget.repo, item: item),
                        );
                      },
                    ),
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
    // back が無い（画像）場合でも “重なり感” を出したいなら、
    // back = front を使うのもアリ。ここでは「画像は1枚、PDFは2枚」にしています。
    return Stack(
      children: [
        // 背後（中間ページ）
        if (back != null)
          Positioned(
            left: 10,
            top: 6,
            right: 0,
            bottom: 0,
            child: _ThumbCard(bytes: back!, elevation: 2, dim: true),
          ),

        // 表紙
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
                0.85, 0, 0, 0, 0,
                0, 0.85, 0, 0, 0,
                0, 0, 0.85, 0, 0,
                0, 0, 0, 1, 0,
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
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Center(
        child: loading
            ? const CircularProgressIndicator(strokeWidth: 2)
            : const Icon(Icons.broken_image),
      ),
    );
  }
}