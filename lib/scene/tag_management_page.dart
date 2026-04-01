import 'package:flutter/material.dart';

import '../database/tag_service.dart';
import '../models/folder.dart';
import '../models/mediaItem.dart';
import '../models/tag.dart';
import '../models/tag_with_id.dart';
import '../repository/mediaRepository.dart';
import 'TagResults.dart';
import 'widgets/scene_ui.dart';

class TagManagementPage extends StatefulWidget {
  final TagService tagService;
  final MediaRepository repo;
  final List<String> folderRaws;

  const TagManagementPage({
    super.key,
    required this.tagService,
    required this.repo,
    required this.folderRaws,
  });

  @override
  State<TagManagementPage> createState() => _TagManagementPageState();
}

class _TagManagementPageState extends State<TagManagementPage> {
  final TextEditingController _searchController = TextEditingController();

  TagCategory _category = TagCategory.artist;
  String _query = '';
  late Future<List<TagWithId>> _future;
  late Future<_TagUsageIndex> _usageFuture;

  @override
  void initState() {
    super.initState();
    _future = _loadTags();
    _usageFuture = _loadUsageIndex();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<List<TagWithId>> _loadTags() {
    return widget.tagService.listTagMasterByCategory(
      _category,
      contains: _query.trim().isEmpty ? null : _query.trim(),
      limit: 500,
    );
  }

  Future<_TagUsageIndex> _loadUsageIndex() async {
    final all = <MediaItem>[];
    final seen = <String>{};

    for (final folderRaw in widget.folderRaws) {
      final loaded = await widget.repo.listMediaRecursiveFiles(FolderHandle(folderRaw));
      for (final item in loaded) {
        if (item.kind == MediaKind.folder) {
          continue;
        }
        if (seen.add(item.id)) {
          all.add(item);
        }
      }
    }

    if (all.isEmpty) {
      return const _TagUsageIndex.empty();
    }

    widget.tagService.rememberItems(all);
    final details = await widget.tagService.getDetailedTagsByItems(all);

    final counts = <String, int>{};
    final previews = <String, List<MediaItem>>{};

    for (final item in all) {
      final tags = details[item.id] ?? const <TagWithId>[];
      final seenInItem = <String>{};
      for (final entry in tags) {
        final key = _usageKey(entry.tag.category, entry.tag.name);
        if (!seenInItem.add(key)) {
          continue;
        }

        counts[key] = (counts[key] ?? 0) + 1;
        if (entry.tag.category == TagCategory.artist) {
          final bucket = previews.putIfAbsent(key, () => <MediaItem>[]);
          if (bucket.length < 3) {
            bucket.add(item);
          }
        }
      }
    }

    return _TagUsageIndex(counts: counts, artistPreviews: previews);
  }

  Future<void> _refresh() async {
    final nextTags = _loadTags();
    final nextUsage = _loadUsageIndex();
    if (!mounted) {
      _future = nextTags;
      _usageFuture = nextUsage;
      return;
    }
    setState(() {
      _future = nextTags;
      _usageFuture = nextUsage;
    });
    await Future.wait<void>(<Future<void>>[
      nextTags.then((_) {}),
      nextUsage.then((_) {}),
    ]);
  }

  void _setCategory(TagCategory category) {
    if (_category == category) {
      return;
    }
    setState(() {
      _category = category;
      _future = _loadTags();
    });
  }

  void _setQuery(String value) {
    setState(() {
      _query = value;
      _future = _loadTags();
    });
  }

  String _categoryLabel(TagCategory category) {
    switch (category) {
      case TagCategory.artist:
        return '作家';
      case TagCategory.series:
        return 'シリーズ';
      case TagCategory.mediaType:
        return '種別';
      case TagCategory.character:
        return 'キャラ';
      case TagCategory.free:
        return '自由';
    }
  }

  IconData _categoryIcon(TagCategory category) {
    switch (category) {
      case TagCategory.artist:
        return Icons.person_outline;
      case TagCategory.series:
        return Icons.collections_bookmark_outlined;
      case TagCategory.mediaType:
        return Icons.category_outlined;
      case TagCategory.character:
        return Icons.face_outlined;
      case TagCategory.free:
        return Icons.sell_outlined;
    }
  }

  Future<void> _openTagResults(TagWithId entry) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => TagResultsPage(
          tagService: widget.tagService,
          repo: widget.repo,
          folderRaws: widget.folderRaws,
          category: entry.tag.category,
          tagName: entry.tag.name,
        ),
      ),
    );
    await _refresh();
  }

  Future<void> _deleteTag(TagWithId entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('タグを削除しますか？'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('このタグは全アイテムから外れ、タグ一覧からも消えます。'),
              const SizedBox(height: 12),
              Text(
                '${_categoryLabel(entry.tag.category)}: ${entry.tag.name}',
                style: Theme.of(dialogContext).textTheme.titleMedium,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('削除'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      return;
    }

    try {
      await widget.tagService.deleteTagMaster(entry);
      await _refresh();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('タグを削除しました: ${entry.tag.name}')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('タグ削除に失敗しました: $error')),
      );
    }
  }

  String _usageKey(TagCategory category, String name) {
    return '${category.name}\u0000${name.trim().toLowerCase()}';
  }

  Widget _buildPreviewThumb(MediaItem item) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: FutureBuilder<ThumbPair>(
        future: widget.repo.readThumbPair(item, maxWidth: 180),
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
              child: const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          }
          return Image.memory(
            snapshot.data!.front,
            fit: BoxFit.cover,
            gaplessPlayback: true,
          );
        },
      ),
    );
  }

  Widget _buildArtistPreview(
    _TagUsageSummary summary,
  ) {
    if (summary.previewItems.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final item in summary.previewItems)
            SizedBox(
              width: 110,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AspectRatio(
                    aspectRatio: 3 / 4,
                    child: _buildPreviewThumb(item),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    item.displayName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          if (summary.count > summary.previewItems.length)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '+${summary.count - summary.previewItems.length} 件',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTagCard(
    TagWithId entry,
    _TagUsageSummary summary, {
    required bool usageReady,
    required bool usageFailed,
  }) {
    final subtitle = usageReady
        ? '${_categoryLabel(entry.tag.category)} · ${summary.count}件'
        : usageFailed
            ? '${_categoryLabel(entry.tag.category)} · 件数取得に失敗しました'
            : '${_categoryLabel(entry.tag.category)} · 集計中...';

    return SceneSurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          ListTile(
            leading: CircleAvatar(
              radius: 18,
              child: Icon(_categoryIcon(entry.tag.category), size: 18),
            ),
            title: Text(entry.tag.name),
            subtitle: Text(subtitle),
            onTap: () => _openTagResults(entry),
            trailing: IconButton(
              tooltip: 'タグを削除',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _deleteTag(entry),
            ),
          ),
          if (entry.tag.category == TagCategory.artist && usageReady)
            _buildArtistPreview(summary),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final categories = TagCategory.values;

    return Scaffold(
      appBar: AppBar(
        title: const Text('タグ管理'),
        actions: [
          IconButton(
            tooltip: '再読み込み',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: SceneSearchField(
              controller: _searchController,
              hintText: 'タグ名で検索',
              onChanged: _setQuery,
              onClear: () {
                _searchController.clear();
                _setQuery('');
              },
            ),
          ),
          SizedBox(
            height: 48,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              scrollDirection: Axis.horizontal,
              itemCount: categories.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final category = categories[index];
                return ChoiceChip(
                  avatar: Icon(_categoryIcon(category), size: 18),
                  label: Text(_categoryLabel(category)),
                  selected: _category == category,
                  onSelected: (_) => _setCategory(category),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: FutureBuilder<List<TagWithId>>(
              future: _future,
              builder: (context, tagSnapshot) {
                if (tagSnapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (tagSnapshot.hasError) {
                  return SceneEmptyState(
                    icon: Icons.error_outline,
                    title: 'タグ一覧の読み込みに失敗しました',
                    message: '${tagSnapshot.error}',
                  );
                }

                final items = tagSnapshot.data ?? const <TagWithId>[];
                if (items.isEmpty) {
                  return const SceneEmptyState(
                    icon: Icons.sell_outlined,
                    title: '該当するタグがありません',
                    message: '検索条件を変えるか、別カテゴリを選んでください。',
                  );
                }

                return FutureBuilder<_TagUsageIndex>(
                  future: _usageFuture,
                  builder: (context, usageSnapshot) {
                    final usageIndex = usageSnapshot.data ?? const _TagUsageIndex.empty();
                    final usageReady =
                        usageSnapshot.connectionState == ConnectionState.done &&
                        !usageSnapshot.hasError;
                    final usageFailed = usageSnapshot.hasError;

                    return ListView.separated(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                      itemCount: items.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final entry = items[index];
                        final summary = usageIndex.summaryFor(entry.tag);
                        return _buildTagCard(
                          entry,
                          summary,
                          usageReady: usageReady,
                          usageFailed: usageFailed,
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _TagUsageIndex {
  final Map<String, int> counts;
  final Map<String, List<MediaItem>> artistPreviews;

  const _TagUsageIndex({
    required this.counts,
    required this.artistPreviews,
  });

  const _TagUsageIndex.empty()
      : counts = const <String, int>{},
        artistPreviews = const <String, List<MediaItem>>{};

  _TagUsageSummary summaryFor(Tag tag) {
    final key = '${tag.category.name}\u0000${tag.name.trim().toLowerCase()}';
    return _TagUsageSummary(
      count: counts[key] ?? 0,
      previewItems: artistPreviews[key] ?? const <MediaItem>[],
    );
  }
}

class _TagUsageSummary {
  final int count;
  final List<MediaItem> previewItems;

  const _TagUsageSummary({
    required this.count,
    required this.previewItems,
  });
}
