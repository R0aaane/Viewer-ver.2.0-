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

  String _categoryLabel(model.TagCategory c) {
    switch (c) {
      case model.TagCategory.artist:
        return '作者';
      case model.TagCategory.series:
        return 'シリーズ';
      case model.TagCategory.mediaType:
        return '種別';
      case model.TagCategory.character:
        return 'キャラ';
      case model.TagCategory.free:
        return '自由';
    }
  }

  String _shortFolder(String raw) {
    final parts = raw
        .split(RegExp(r'[\/]+'))
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    return parts.isEmpty ? raw : parts.last;
  }


  Widget _coverThumb(MediaItem item) {
    return AspectRatio(
      aspectRatio: 3 / 4,
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
              snap.data!.front,
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

    // フォルダ全件を取得
    List<MediaItem> items;
    if (_folderItemsCache.containsKey(folderRaw)) {
      items = _folderItemsCache[folderRaw]!;
    } else {
      items = await widget.repo.listMedia(FolderHandle(folderRaw));
      _folderItemsCache[folderRaw] = items;
    }

    // ファイルindex を特定
    final idx = items.indexWhere((e) => e.id == item.id);
    if (!mounted) return;
    if (idx < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ファイルが見つかりません（移動/削除された可能性）')),
      );
      return;
    }

    // detailページへ遷移
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
      appBar: AppBar(title: Text('${_categoryLabel(widget.category)}: ${widget.tagName}')),
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

          // 作品名で見やすくソート
          final sorted = items.toList(growable: true)
            ..sort(
              (a, b) => a.displayName.toLowerCase().compareTo(
                b.displayName.toLowerCase(),
              ),
            );

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
                                'フォルダ: ${_shortFolder(it.folderRaw)}',
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
