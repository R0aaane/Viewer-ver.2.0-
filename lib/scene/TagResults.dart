import 'package:flutter/material.dart';

import '../database/tag_service.dart';
import '../models/folder.dart';
import '../models/mediaItem.dart';
import '../models/tag.dart' as model;
import '../repository/mediaRepository.dart';
import 'detailImage.dart';
import 'widgets/scene_ui.dart';

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
  final Map<String, List<MediaItem>> _folderItemsCache =
      <String, List<MediaItem>>{};

  String _categoryLabel(model.TagCategory category) {
    switch (category) {
      case model.TagCategory.artist:
        return '作者';
      case model.TagCategory.series:
        return 'シリーズ';
      case model.TagCategory.mediaType:
        return '媒体';
      case model.TagCategory.character:
        return 'キャラ';
      case model.TagCategory.free:
        return '自由';
    }
  }

  String _shortFolder(String raw) {
    final parts = raw
        .split(RegExp(r'[\\\/]+'))
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    return parts.isEmpty ? raw : parts.last;
  }

  Widget _coverThumb(MediaItem item) {
    return AspectRatio(
      aspectRatio: 3 / 4,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: FutureBuilder<ThumbPair>(
          future: widget.repo.readThumbPair(item, maxWidth: 240),
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return Container(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                alignment: Alignment.center,
                child: const CircularProgressIndicator(strokeWidth: 2),
              );
            }
            return Image.memory(
              snapshot.data!.front,
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

    final items = _folderItemsCache.putIfAbsent(folderRaw, () => <MediaItem>[]);
    if (items.isEmpty) {
      final loaded = await widget.repo.listMedia(FolderHandle(folderRaw));
      _folderItemsCache[folderRaw] = loaded;
    }

    final folderItems = _folderItemsCache[folderRaw]!;
    final index = folderItems.indexWhere((entry) => entry.id == item.id);
    if (!mounted) return;

    if (index < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ファイルが見つかりませんでした')),
      );
      return;
    }

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ImageDetailPage(
          repo: widget.repo,
          tagService: widget.tagService,
          items: folderItems,
          initialIndex: index,
          initialPdfPage: 1,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${_categoryLabel(widget.category)}: ${widget.tagName}'),
      ),
      body: FutureBuilder<List<MediaItem>>(
        future: widget.tagService.findMediaItemsByTagGlobal(
          category: widget.category,
          name: widget.tagName,
          partial: false,
        ),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final items = snapshot.data!;
          if (items.isEmpty) {
            return const SceneEmptyState(
              icon: Icons.label_off_outlined,
              title: '一致するアイテムがありません',
            );
          }

          final sorted = items.toList(growable: true)
            ..sort(
              (left, right) => left.displayName.toLowerCase().compareTo(
                right.displayName.toLowerCase(),
              ),
            );

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: sorted.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final item = sorted[index];
              return Card(
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => _openDetail(item),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 84,
                          height: 112,
                          child: _coverThumb(item),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.displayName,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  Chip(
                                    label: Text(
                                      item.kind == MediaKind.pdf ? 'PDF' : '画像',
                                    ),
                                  ),
                                  Chip(
                                    label: Text(
                                      _shortFolder(item.folderRaw),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
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
