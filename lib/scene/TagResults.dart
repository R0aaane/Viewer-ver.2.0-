import 'package:flutter/material.dart';

import '../database/tag_service.dart';
import '../models/tag.dart' as model;
import '../models/mediaItem.dart';
import '../models/folder.dart';
import '../repository/mediaRepository.dart';

import 'detailImage.dart';

class TagResultsPage extends StatefulWidget {
  final TagService tagService;
  final MediaRepository repo;
  final model.TagCategory category;
  final String tagName;

  const TagResultsPage({
    super.key,
    required this.tagService,
    required this.repo,
    required this.category,
    required this.tagName,
  });

  @override
  State<TagResultsPage> createState() => _TagResultsPageState();
}

class _TagResultsPageState extends State<TagResultsPage> {
  // folderRaw -> items（そのフォルダの全件）
  final Map<String, List<MediaItem>> _folderItemsCache = {};

  Widget _coverThumb(MediaItem item) {
    return AspectRatio(
      aspectRatio: 3 / 4, // 縦長（漫画・PDF向け）
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: FutureBuilder<ThumbPair>(
          future: widget.repo.readThumbPair(item, maxWidth: 240),
          builder: (context, snap) {
            if (!snap.hasData) {
              return Container(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                alignment: Alignment.center,
                child: const CircularProgressIndicator(strokeWidth: 2),
              );
            }
            return Image.memory(
              snap.data!.front, // ★PDFは表紙、画像はその画像
              fit: BoxFit.cover,
              gaplessPlayback: true,
            );
          },
        ),
      ),
    );
  }

  Future<void> _openDetail(MediaItem item) async {
    final folderRaw = item.folderRaw;

    // 1) フォルダ全件を取得（キャッシュ）
    List<MediaItem> items;
    if (_folderItemsCache.containsKey(folderRaw)) {
      items = _folderItemsCache[folderRaw]!;
    } else {
      items = await widget.repo.listMedia(FolderHandle(folderRaw));
      _folderItemsCache[folderRaw] = items;
    }

    // 2) index を特定
    final idx = items.indexWhere((e) => e.id == item.id);
    if (!mounted) return;
    if (idx < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ファイルが見つかりません（移動/削除された可能性）')),
      );
      return;
    }

    // 3) detailへ遷移（あなたの detailImage.dart のコンストラクタに合わせる）
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ImageDetailPage(
          repo: widget.repo,
          tagService: widget.tagService,
          items: items,
          initialIndex: idx,
          initialPdfPage: 1,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('アーティスト: ${widget.tagName}'),
      ),
      body: FutureBuilder<List<MediaItem>>(
        future: widget.tagService.findMediaItemsByTagGlobal(
          category: widget.category,
          name: widget.tagName,
          partial: false,
        ),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snap.data!;
          if (items.isEmpty) {
            return const Center(child: Text('該当なし'));
          }

          // 作品名で見やすくソート（任意）
          final sorted = items.toList(growable: true)
            ..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));

          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: sorted.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, i) {
              final it = sorted[i];
              return Card(
                child: InkWell(
                  onTap: () => _openDetail(it),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(height: 104, child: _coverThumb(it)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                it.displayName,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 6),
                              Text(
                                it.kind == MediaKind.pdf ? 'PDF' : '画像',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'フォルダ: ${it.folderRaw}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}