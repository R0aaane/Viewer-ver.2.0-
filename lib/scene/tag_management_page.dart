import 'package:flutter/material.dart';

import '../database/tag_service.dart';
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

  @override
  void initState() {
    super.initState();
    _future = _loadTags();
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

  Future<void> _refresh() async {
    final next = _loadTags();
    if (!mounted) {
      _future = next;
      return;
    }
    setState(() => _future = next);
    await next;
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
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return SceneEmptyState(
                    icon: Icons.error_outline,
                    title: 'タグ一覧の読み込みに失敗しました',
                    message: '${snapshot.error}',
                  );
                }

                final items = snapshot.data ?? const <TagWithId>[];
                if (items.isEmpty) {
                  return const SceneEmptyState(
                    icon: Icons.sell_outlined,
                    title: '該当するタグがありません',
                    message: '検索条件を変えるか、別カテゴリを選んでください。',
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final entry = items[index];
                    return SceneSurfaceCard(
                      padding: EdgeInsets.zero,
                      child: ListTile(
                        leading: CircleAvatar(
                          radius: 18,
                          child: Icon(_categoryIcon(entry.tag.category), size: 18),
                        ),
                        title: Text(entry.tag.name),
                        subtitle: Text(_categoryLabel(entry.tag.category)),
                        onTap: () => _openTagResults(entry),
                        trailing: IconButton(
                          tooltip: 'タグを削除',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _deleteTag(entry),
                        ),
                      ),
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
