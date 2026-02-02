import 'dart:typed_data';
import 'package:flutter/material.dart';

import '../models/mediaItem.dart';
import '../repository/mediaRepository.dart';
import 'viewImage.dart';

class ImageDetailPage extends StatelessWidget {
  final MediaRepository repo;
  final List<MediaItem> items;
  final int index;

  const ImageDetailPage({
    super.key,
    required this.repo,
    required this.items,
    required this.index,
  });

  @override
  Widget build(BuildContext context) {
    final item = items[index];

    void openViewer() {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ImageViewerPage(
            repo: repo,
            items: items,
            initialIndex: index,
          ),
        ),
      );
    }

    // ★ PDFは表紙だけ（readThumbPair(item).front）を使う
    final Future<Uint8List> futureBytes = (item.kind == MediaKind.pdf)
        ? repo.readThumbPair(item, maxWidth: 900).then((p) => p.front)
        : repo.readBytes(item);

    return Scaffold(
      appBar: AppBar(title: const Text('詳細表示')),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: FutureBuilder<Uint8List>(
                future: futureBytes,
                builder: (context, snap) {
                  if (!snap.hasData) {
                    return const CircularProgressIndicator();
                  }
                  return GestureDetector(
                    onTap: openViewer,
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
                Expanded(
                  child: Text(
                    item.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: openViewer,
                  child: const Text('画像を閲覧'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
