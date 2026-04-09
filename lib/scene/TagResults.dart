import 'package:flutter/material.dart';

import '../database/tag_service.dart';
import '../models/folder.dart';
import '../models/mediaItem.dart';
import '../models/tag.dart' as model;
import '../repository/mediaRepository.dart';
import '../services/item_name_service.dart';
import 'detailImage.dart';
import 'widgets/scene_ui.dart';

class TagResultsPage extends StatefulWidget {
  final TagService tagService;
  final MediaRepository repo;
  final List<String> folderRaws;
  final model.TagCategory category;
  final String tagName;

  const TagResultsPage({
    super.key,
    required this.tagService,
    required this.repo,
    required this.folderRaws,
    required this.category,
    required this.tagName,
  });

  @override
  State<TagResultsPage> createState() => _TagResultsPageState();
}

class _TagResultsPageState extends State<TagResultsPage> {
  final Map<String, List<MediaItem>> _folderItemsCache =
      <String, List<MediaItem>>{};
  late Future<List<MediaItem>> _resultsFuture;

  @override
  void initState() {
    super.initState();
    _resultsFuture = _loadResults();
  }

  Future<void> _refreshResults() async {
    final next = _loadResults();
    if (!mounted) {
      _resultsFuture = next;
      return;
    }
    setState(() => _resultsFuture = next);
    await next;
  }

  Future<List<MediaItem>> _loadResults() {
    return widget.tagService.findMediaItemsByTagAcrossFolders(
      category: widget.category,
      name: widget.tagName,
      repo: widget.repo,
      folderRaws: widget.folderRaws,
    );
  }

  String _categoryLabel(model.TagCategory category) {
    switch (category) {
      case model.TagCategory.artist:
        return 'アーティスト';
      case model.TagCategory.series:
        return 'シリーズ';
      case model.TagCategory.mediaType:
        return 'メディア種別';
      case model.TagCategory.character:
        return 'キャラクター';
      case model.TagCategory.free:
        return '自由タグ';
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
            if (snapshot.hasError) {
              return Container(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                alignment: Alignment.center,
                child: const Icon(Icons.broken_image_outlined),
              );
            }
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
    try {
      if (items.isEmpty) {
        final loaded = await widget.repo.listMedia(FolderHandle(folderRaw));
        _folderItemsCache[folderRaw] = loaded;
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('フォルダの読み込みに失敗しました: $error')),
      );
      return;
    }

    final folderItems = _folderItemsCache[folderRaw]!;
    final index = folderItems.indexWhere((entry) => entry.id == item.id);
    if (!mounted) return;

    if (index < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('対象アイテムがフォルダ内に見つかりませんでした')),
      );
      return;
    }

    final changed = await Navigator.push<bool>(
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
    if (changed == true && mounted) {
      await _refreshResults();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${_categoryLabel(widget.category)}: ${widget.tagName}'),
        actions: [
          IconButton(
            tooltip: '再読み込み',
            onPressed: () => _refreshResults(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<List<MediaItem>>(
        future: _resultsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return RefreshIndicator(
              onRefresh: _refreshResults,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                ),
                children: const [
                  SizedBox(
                    height: 320,
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ],
              ),
            );
          }
          if (snapshot.hasError) {
            return RefreshIndicator(
              onRefresh: _refreshResults,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                ),
                children: [
                  SizedBox(
                    height: MediaQuery.of(context).size.height * 0.6,
                    child: SceneEmptyState(
                      icon: Icons.error_outline,
                      title: 'タグ結果の読み込みに失敗しました',
                      message: '${snapshot.error}',
                    ),
                  ),
                ],
              ),
            );
          }

          final items = snapshot.data ?? const <MediaItem>[];
          if (items.isEmpty) {
            return RefreshIndicator(
              onRefresh: _refreshResults,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                ),
                children: const [
                  SizedBox(
                    height: 320,
                    child: SceneEmptyState(
                      icon: Icons.label_off_outlined,
                      title: 'このタグの作品はありません',
                      message: 'タグだけが残っているか、対象作品が見つかりませんでした。',
                    ),
                  ),
                ],
              ),
            );
          }

          final sorted = items.toList(growable: true)
            ..sort(
              (left, right) => left.displayName.toLowerCase().compareTo(
                right.displayName.toLowerCase(),
              ),
            );

          return RefreshIndicator(
            onRefresh: _refreshResults,
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics(),
              ),
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
                                  ItemNameService.formatMediaTitle(
                                    item.displayName,
                                    kind: item.kind,
                                  ),
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
            ),
          );
        },
      ),
    );
  }
}
