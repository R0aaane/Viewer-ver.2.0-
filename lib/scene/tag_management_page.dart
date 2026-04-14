import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../database/tag_service.dart';
import '../models/folder.dart';
import '../models/mediaItem.dart';
import '../models/tag.dart';
import '../repository/mediaRepository.dart';
import 'TagResults.dart';
import 'widgets/scene_ui.dart';

enum _TagViewMode { list, card }

enum _TagSortMode { countDesc, nameAsc, recentDesc }

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

  late Future<_TagManagementData> _future;

  final Set<int> _selectedTagIds = <int>{};
  final Map<String, List<TagWithId>> _mergeSuggestionCache =
      <String, List<TagWithId>>{};

  TagCategory? _categoryFilter;
  _TagViewMode _viewMode = _TagViewMode.list;
  _TagSortMode _sortMode = _TagSortMode.countDesc;
  String _query = '';
  bool _runningAction = false;

  @override
  void initState() {
    super.initState();
    _future = _loadPageData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<_TagManagementData> _loadPageData() async {
    _mergeSuggestionCache.clear();
    final results = await Future.wait<Object>(<Future<Object>>[
      _loadAllTagMasters(),
      _loadUsageIndex(),
    ]);
    final tags = results[0] as List<TagWithId>;
    final usageIndex = results[1] as _TagUsageIndex;
    return _TagManagementData(
      tags: tags,
      usageIndex: usageIndex,
      categoryCounts: _countByCategory(tags),
    );
  }

  Future<List<TagWithId>> _loadAllTagMasters() async {
    final loaded = await Future.wait<List<TagWithId>>(
      TagCategory.values.map(
        (category) =>
            widget.tagService.listTagMasterByCategory(category, limit: 5000),
      ),
    );

    final deduped = <String, TagWithId>{};
    for (final group in loaded) {
      for (final entry in group) {
        deduped.putIfAbsent(
          _usageKey(entry.tag.category, entry.tag.name),
          () => entry,
        );
      }
    }

    final tags = deduped.values.toList(growable: true);
    tags.sort((left, right) {
      final categoryCompare = _categoryOrder(
        left.tag.category,
      ).compareTo(_categoryOrder(right.tag.category));
      if (categoryCompare != 0) {
        return categoryCompare;
      }
      return left.tag.name.toLowerCase().compareTo(
        right.tag.name.toLowerCase(),
      );
    });
    return tags;
  }

  Future<_TagUsageIndex> _loadUsageIndex() async {
    final all = <MediaItem>[];
    final seen = <String>{};

    for (final folderRaw in widget.folderRaws) {
      final loaded = await widget.repo.listMediaRecursiveFiles(
        FolderHandle(folderRaw),
      );
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

    all.sort((left, right) {
      final rightTs = _itemTimestamp(right).millisecondsSinceEpoch;
      final leftTs = _itemTimestamp(left).millisecondsSinceEpoch;
      return rightTs.compareTo(leftTs);
    });

    widget.tagService.rememberItems(all);
    final details = await widget.tagService.getDetailedTagsByItems(all);

    final counts = <String, int>{};
    final previews = <String, List<MediaItem>>{};
    final lastUsedAt = <String, DateTime>{};

    for (final item in all) {
      final timestamp = _itemTimestamp(item);
      final tags = details[item.id] ?? const <TagWithId>[];
      final seenInItem = <String>{};
      for (final entry in tags) {
        final key = _usageKey(entry.tag.category, entry.tag.name);
        if (!seenInItem.add(key)) {
          continue;
        }

        counts[key] = (counts[key] ?? 0) + 1;

        final existingLatest = lastUsedAt[key];
        if (existingLatest == null ||
            timestamp.millisecondsSinceEpoch >
                existingLatest.millisecondsSinceEpoch) {
          lastUsedAt[key] = timestamp;
        }

        final bucket = previews.putIfAbsent(key, () => <MediaItem>[]);
        if (bucket.length < 3) {
          bucket.add(item);
        }
      }
    }

    final summaries = <String, _TagUsageSummary>{};
    final keys = <String>{...counts.keys, ...previews.keys, ...lastUsedAt.keys};
    for (final key in keys) {
      summaries[key] = _TagUsageSummary(
        count: counts[key] ?? 0,
        previewItems: previews[key] ?? const <MediaItem>[],
        lastUsedAt: lastUsedAt[key],
      );
    }

    return _TagUsageIndex(summaries: summaries);
  }

  DateTime _itemTimestamp(MediaItem item) {
    return item.modified ?? DateTime.fromMillisecondsSinceEpoch(0);
  }

  Future<void> _refresh({bool clearSelection = false}) async {
    final next = _loadPageData();
    if (!mounted) {
      _future = next;
      return;
    }
    setState(() {
      _future = next;
      if (clearSelection) {
        _selectedTagIds.clear();
      }
    });
    await next;
  }

  Map<TagCategory, int> _countByCategory(Iterable<TagWithId> tags) {
    final counts = <TagCategory, int>{};
    for (final category in TagCategory.values) {
      counts[category] = 0;
    }
    for (final entry in tags) {
      counts[entry.tag.category] = (counts[entry.tag.category] ?? 0) + 1;
    }
    return counts;
  }

  void _setCategoryFilter(TagCategory? category) {
    setState(() {
      _categoryFilter = category;
    });
  }

  void _setQuery(String value) {
    setState(() {
      _query = value.trim();
    });
  }

  void _setSortMode(_TagSortMode value) {
    if (_sortMode == value) {
      return;
    }
    setState(() {
      _sortMode = value;
    });
  }

  void _setViewMode(_TagViewMode value) {
    if (_viewMode == value) {
      return;
    }
    setState(() {
      _viewMode = value;
    });
  }

  int _categoryOrder(TagCategory category) {
    switch (category) {
      case TagCategory.artist:
        return 0;
      case TagCategory.series:
        return 1;
      case TagCategory.character:
        return 2;
      case TagCategory.mediaType:
        return 3;
      case TagCategory.free:
        return 4;
    }
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

  Color _categoryColor(BuildContext context, TagCategory category) {
    switch (category) {
      case TagCategory.artist:
        return const Color(0xFFE49BB8);
      case TagCategory.series:
        return const Color(0xFFA1C6FF);
      case TagCategory.mediaType:
        return const Color(0xFFE7B476);
      case TagCategory.character:
        return const Color(0xFF8DD6B3);
      case TagCategory.free:
        return Theme.of(context).colorScheme.primary;
    }
  }

  List<_ResolvedTagEntry> _resolveEntries(_TagManagementData data) {
    final query = _query.toLowerCase();
    final filtered = <_ResolvedTagEntry>[];

    for (final entry in data.tags) {
      if (_categoryFilter != null && entry.tag.category != _categoryFilter) {
        continue;
      }
      if (query.isNotEmpty && !_matchesQuery(entry, query)) {
        continue;
      }

      filtered.add(
        _ResolvedTagEntry(
          entry: entry,
          summary: data.usageIndex.summaryFor(entry.tag),
          mergeSuggestions: _mergeSuggestionsFor(entry, data),
        ),
      );
    }

    filtered.sort((left, right) {
      switch (_sortMode) {
        case _TagSortMode.countDesc:
          final countCompare = right.summary.count.compareTo(
            left.summary.count,
          );
          if (countCompare != 0) {
            return countCompare;
          }
          break;
        case _TagSortMode.nameAsc:
          final nameCompare = left.entry.tag.name.toLowerCase().compareTo(
            right.entry.tag.name.toLowerCase(),
          );
          if (nameCompare != 0) {
            return nameCompare;
          }
          break;
        case _TagSortMode.recentDesc:
          final rightTs = right.summary.lastUsedAt?.millisecondsSinceEpoch ?? 0;
          final leftTs = left.summary.lastUsedAt?.millisecondsSinceEpoch ?? 0;
          final recentCompare = rightTs.compareTo(leftTs);
          if (recentCompare != 0) {
            return recentCompare;
          }
          break;
      }

      final categoryCompare = _categoryOrder(
        left.entry.tag.category,
      ).compareTo(_categoryOrder(right.entry.tag.category));
      if (categoryCompare != 0) {
        return categoryCompare;
      }

      final countCompare = right.summary.count.compareTo(left.summary.count);
      if (countCompare != 0) {
        return countCompare;
      }

      return left.entry.tag.name.toLowerCase().compareTo(
        right.entry.tag.name.toLowerCase(),
      );
    });

    return filtered;
  }

  bool _matchesQuery(TagWithId entry, String query) {
    return entry.tag.name.toLowerCase().contains(query) ||
        _categoryLabel(entry.tag.category).toLowerCase().contains(query);
  }

  List<TagWithId> _mergeSuggestionsFor(
    TagWithId source,
    _TagManagementData data,
  ) {
    final key = _usageKey(source.tag.category, source.tag.name);
    final cached = _mergeSuggestionCache[key];
    if (cached != null) {
      return cached;
    }

    final scored = <_ScoredMergeCandidate>[];
    for (final candidate in data.tags) {
      if (candidate.tag.category != source.tag.category ||
          candidate.tagId == source.tagId) {
        continue;
      }

      final score = _mergeSuggestionScore(source.tag.name, candidate.tag.name);
      if (score == null) {
        continue;
      }

      scored.add(
        _ScoredMergeCandidate(
          entry: candidate,
          score: score,
          count: data.usageIndex.summaryFor(candidate.tag).count,
        ),
      );
    }

    scored.sort((left, right) {
      final scoreCompare = right.score.compareTo(left.score);
      if (scoreCompare != 0) {
        return scoreCompare;
      }
      final countCompare = right.count.compareTo(left.count);
      if (countCompare != 0) {
        return countCompare;
      }
      return left.entry.tag.name.toLowerCase().compareTo(
        right.entry.tag.name.toLowerCase(),
      );
    });

    final next = scored
        .take(4)
        .map((candidate) => candidate.entry)
        .toList(growable: false);
    _mergeSuggestionCache[key] = next;
    return next;
  }

  int? _mergeSuggestionScore(String source, String candidate) {
    final left = _normalizedMergeName(source);
    final right = _normalizedMergeName(candidate);
    if (left.isEmpty || right.isEmpty || left == right) {
      return null;
    }

    if (left.startsWith(right) || right.startsWith(left)) {
      return 100 - (left.length - right.length).abs();
    }
    if (left.contains(right) || right.contains(left)) {
      return 80 - (left.length - right.length).abs();
    }

    final distance = _levenshteinDistance(left, right);
    if (distance <= 2) {
      return 60 - distance;
    }
    if (distance <= 3 && left.length >= 5 && right.length >= 5) {
      return 45 - distance;
    }
    return null;
  }

  String _normalizedMergeName(String raw) {
    return raw.trim().toLowerCase().replaceAll(
      RegExp(r'[\s_\-#\(\)\[\]\{\}\.,/]+'),
      '',
    );
  }

  int _levenshteinDistance(String left, String right) {
    if (left == right) {
      return 0;
    }
    if (left.isEmpty) {
      return right.length;
    }
    if (right.isEmpty) {
      return left.length;
    }

    final previous = List<int>.generate(right.length + 1, (index) => index);
    for (var i = 0; i < left.length; i++) {
      var current = i + 1;
      var diagonal = i;
      for (var j = 0; j < right.length; j++) {
        final replaceCost = left.codeUnitAt(i) == right.codeUnitAt(j) ? 0 : 1;
        final nextDiagonal = previous[j + 1];
        final value = math.min(
          math.min(previous[j + 1] + 1, current + 1),
          diagonal + replaceCost,
        );
        previous[j] = current;
        current = value;
        diagonal = nextDiagonal;
      }
      previous[right.length] = current;
    }
    return previous[right.length];
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

  void _toggleSelection(int tagId) {
    setState(() {
      if (!_selectedTagIds.add(tagId)) {
        _selectedTagIds.remove(tagId);
      }
    });
  }

  void _selectVisibleEntries(List<_ResolvedTagEntry> entries) {
    setState(() {
      _selectedTagIds.addAll(entries.map((entry) => entry.entry.tagId));
    });
  }

  void _clearSelection() {
    if (_selectedTagIds.isEmpty) {
      return;
    }
    setState(() {
      _selectedTagIds.clear();
    });
  }

  Future<void> _runAction(Future<void> Function() action) async {
    if (_runningAction) {
      return;
    }

    setState(() {
      _runningAction = true;
    });
    try {
      await action();
    } finally {
      if (mounted) {
        setState(() {
          _runningAction = false;
        });
      }
    }
  }

  Future<void> _confirmDelete(List<TagWithId> entries) async {
    if (entries.isEmpty) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final preview = entries.take(6).map((entry) => entry.tag.name).toList();
        return AlertDialog(
          title: Text(entries.length == 1 ? 'タグを削除' : '選択タグを一括削除'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                entries.length == 1
                    ? 'このタグを削除します。関連付けも削除されます。'
                    : '${entries.length}件のタグを削除します。関連付けも削除されます。',
              ),
              const SizedBox(height: 12),
              for (final name in preview)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('• $name'),
                ),
              if (entries.length > preview.length)
                Text('ほか ${entries.length - preview.length} 件'),
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

    await _runAction(() async {
      for (final entry in entries) {
        await widget.tagService.deleteTagMaster(entry);
      }
      await _refresh(clearSelection: true);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${entries.length}件のタグを削除しました')));
    });
  }

  Future<void> _showRenameDialog(
    TagWithId source,
    _TagManagementData data,
  ) async {
    final targetName = await _showMergeTargetDialog(
      sources: <TagWithId>[source],
      pool: data.tags,
      title: 'タグ名を変更',
      description: '新しいタグ名へ付け替えて、古いタグを整理します。',
      confirmLabel: '変更する',
      initialTargetName: source.tag.name,
      allowSourceNamesAsTarget: false,
    );
    if (targetName == null) {
      return;
    }

    await _mergeTags(
      sources: <TagWithId>[source],
      targetName: targetName,
      clearSelectionAfter: true,
    );
  }

  Future<void> _showMergeDialog(
    List<TagWithId> sources,
    _TagManagementData data, {
    String? initialTargetName,
  }) async {
    if (sources.isEmpty) {
      return;
    }
    final category = sources.first.tag.category;
    if (sources.any((entry) => entry.tag.category != category)) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('一括統合は同じカテゴリのタグだけ選択してください')));
      return;
    }

    final preferredTarget =
        sources
            .map(
              (entry) => _ResolvedTagEntry(
                entry: entry,
                summary: data.usageIndex.summaryFor(entry.tag),
                mergeSuggestions: const <TagWithId>[],
              ),
            )
            .toList(growable: true)
          ..sort(
            (left, right) => right.summary.count.compareTo(left.summary.count),
          );

    final targetName = await _showMergeTargetDialog(
      sources: sources,
      pool: data.tags,
      title: sources.length == 1 ? 'タグを統合' : '選択タグを統合',
      description: '統合先タグ名を指定すると、選択したタグの付与先をまとめます。',
      confirmLabel: '統合する',
      initialTargetName:
          initialTargetName ?? preferredTarget.first.entry.tag.name,
      allowSourceNamesAsTarget: true,
    );
    if (targetName == null) {
      return;
    }

    await _mergeTags(
      sources: sources,
      targetName: targetName,
      clearSelectionAfter: true,
    );
  }

  Future<String?> _showMergeTargetDialog({
    required List<TagWithId> sources,
    required List<TagWithId> pool,
    required String title,
    required String description,
    required String confirmLabel,
    required String initialTargetName,
    required bool allowSourceNamesAsTarget,
  }) async {
    final category = sources.first.tag.category;
    final selectedKeys = sources
        .map((entry) => _usageKey(entry.tag.category, entry.tag.name))
        .toSet();
    final controller = TextEditingController(text: initialTargetName);

    final suggestionMap = <String, TagWithId>{};
    for (final source in sources) {
      for (final candidate in _mergeSuggestionsFor(
        source,
        _TagManagementData(
          tags: pool,
          usageIndex: const _TagUsageIndex.empty(),
          categoryCounts: const <TagCategory, int>{},
        ),
      )) {
        suggestionMap[_usageKey(candidate.tag.category, candidate.tag.name)] =
            candidate;
      }
    }
    if (allowSourceNamesAsTarget) {
      for (final source in sources) {
        suggestionMap[_usageKey(source.tag.category, source.tag.name)] = source;
      }
    }

    final suggestions = suggestionMap.values.toList(growable: true)
      ..sort(
        (left, right) =>
            left.tag.name.toLowerCase().compareTo(right.tag.name.toLowerCase()),
      );

    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(description),
                const SizedBox(height: 12),
                Text(
                  'カテゴリ: ${_categoryLabel(category)}',
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final source in sources)
                      Chip(
                        label: Text(source.tag.name),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '統合先タグ名',
                    hintText: 'タグ名を入力',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (suggestions.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    '候補',
                    style: Theme.of(dialogContext).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final candidate in suggestions.take(10))
                        ActionChip(
                          label: Text(candidate.tag.name),
                          avatar: Icon(
                            selectedKeys.contains(
                                  _usageKey(
                                    candidate.tag.category,
                                    candidate.tag.name,
                                  ),
                                )
                                ? Icons.call_merge
                                : _categoryIcon(candidate.tag.category),
                            size: 16,
                          ),
                          onPressed: () {
                            controller.text = candidate.tag.name;
                            controller.selection = TextSelection.fromPosition(
                              TextPosition(offset: controller.text.length),
                            );
                          },
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () {
                final value = controller.text.trim();
                if (value.isEmpty) {
                  return;
                }
                Navigator.of(dialogContext).pop(value);
              },
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    );

    controller.dispose();
    return result;
  }

  Future<void> _mergeTags({
    required List<TagWithId> sources,
    required String targetName,
    required bool clearSelectionAfter,
  }) async {
    if (sources.isEmpty) {
      return;
    }

    final category = sources.first.tag.category;
    final trimmedTargetName = targetName.trim();
    if (trimmedTargetName.isEmpty) {
      return;
    }

    final targetTag = Tag(name: trimmedTargetName, category: category);
    final targetKey = _usageKey(category, trimmedTargetName);
    final sourceEntries = sources
        .where(
          (entry) => _usageKey(entry.tag.category, entry.tag.name) != targetKey,
        )
        .toList(growable: false);

    if (sourceEntries.isEmpty) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('統合対象がありません')));
      return;
    }

    Future<List<MediaItem>> findItems(Tag tag) {
      if (widget.tagService.isRemoteMode) {
        return widget.tagService.findMediaItemsByTagAcrossFolders(
          category: tag.category,
          name: tag.name,
          repo: widget.repo,
          folderRaws: widget.folderRaws,
        );
      }
      return widget.tagService.findMediaItemsByTagGlobal(
        category: tag.category,
        name: tag.name,
      );
    }

    await _runAction(() async {
      final targetItems = await findItems(targetTag);
      widget.tagService.rememberItems(targetItems);
      final targetItemIds = targetItems.map((item) => item.id).toSet();

      var mergedTagCount = 0;
      var touchedItemCount = 0;

      for (final source in sourceEntries) {
        final sourceItems = await findItems(source.tag);
        widget.tagService.rememberItems(sourceItems);

        final itemsToAdd = sourceItems
            .where((item) => !targetItemIds.contains(item.id))
            .toList(growable: false);
        if (itemsToAdd.isNotEmpty) {
          await widget.tagService.addTagToItems(itemsToAdd, targetTag);
          targetItemIds.addAll(itemsToAdd.map((item) => item.id));
        }

        for (final item in sourceItems) {
          await widget.tagService.removeTagFromItem(
            item.id,
            source.tagId,
            item: item,
          );
        }

        if (!widget.tagService.isRemoteMode) {
          final remaining = await widget.tagService.findMediaItemsByTagGlobal(
            category: source.tag.category,
            name: source.tag.name,
          );
          if (remaining.isEmpty) {
            await widget.tagService.deleteTagMaster(source);
          }
        }

        touchedItemCount += sourceItems.length;
        mergedTagCount += 1;
      }

      await _refresh(clearSelection: clearSelectionAfter);
      if (!mounted) {
        return;
      }

      final targetLabel = '${_categoryLabel(category)}: $trimmedTargetName';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '$mergedTagCount件のタグを $targetLabel に統合しました'
            '${touchedItemCount > 0 ? ' / 対象 $touchedItemCount 件' : ''}',
          ),
        ),
      );
    });
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

  Widget _buildPreviewStrip(_TagUsageSummary summary) {
    if (summary.previewItems.isEmpty) {
      return Container(
        height: 54,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Text('プレビューなし', style: TextStyle(fontSize: 11)),
      );
    }

    return SizedBox(
      height: 54,
      child: Row(
        children: [
          for (final item in summary.previewItems) ...[
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: AspectRatio(
                  aspectRatio: 3 / 4,
                  child: _buildPreviewThumb(item),
                ),
              ),
            ),
          ],
          for (var i = summary.previewItems.length; i < 3; i++) ...[
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Container(
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCountBadge(_TagUsageSummary summary) {
    final color = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        '${summary.count}件',
        style: TextStyle(color: color, fontWeight: FontWeight.w700),
      ),
    );
  }

  Widget _buildCategoryBadge(TagCategory category) {
    final color = _categoryColor(context, category);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_categoryIcon(category), size: 15, color: color),
          const SizedBox(width: 6),
          Text(
            _categoryLabel(category),
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _buildMergeSuggestionChips(
    _ResolvedTagEntry resolved,
    _TagManagementData data, {
    required int maxSuggestions,
  }) {
    if (resolved.mergeSuggestions.isEmpty) {
      return const SizedBox.shrink();
    }

    final suggestions = resolved.mergeSuggestions
        .take(maxSuggestions)
        .toList(growable: false);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          Text(
            '統合候補',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          for (var i = 0; i < suggestions.length; i++) ...[
            ActionChip(
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              avatar: const Icon(Icons.call_merge, size: 14),
              label: Text(
                '${suggestions[i].tag.name} '
                '${data.usageIndex.summaryFor(suggestions[i].tag).count}件',
              ),
              onPressed: _runningAction
                  ? null
                  : () => _showMergeDialog(
                      <TagWithId>[resolved.entry],
                      data,
                      initialTargetName: suggestions[i].tag.name,
                    ),
            ),
            if (i != suggestions.length - 1) const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }

  String _formatDateTime(DateTime? value) {
    if (value == null || value.millisecondsSinceEpoch <= 0) {
      return '未使用';
    }
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    return '${value.year}/$month/$day $hour:$minute';
  }

  Widget _buildListItem(_ResolvedTagEntry resolved, _TagManagementData data) {
    final entry = resolved.entry;
    final summary = resolved.summary;
    final selected = _selectedTagIds.contains(entry.tagId);

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          if (_selectedTagIds.isNotEmpty) {
            _toggleSelection(entry.tagId);
            return;
          }
          _openTagResults(entry);
        },
        onLongPress: () => _toggleSelection(entry.tagId),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 1180;
              final medium = constraints.maxWidth >= 820;
              final suggestionChips = _buildMergeSuggestionChips(
                resolved,
                data,
                maxSuggestions: wide ? 3 : 2,
              );

              final infoColumn = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          entry.tag.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      const SizedBox(width: 10),
                      _buildCountBadge(summary),
                    ],
                  ),
                  if (resolved.mergeSuggestions.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    suggestionChips,
                  ],
                ],
              );

              final actionRow = Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '編集',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: _runningAction
                        ? null
                        : () => _showRenameDialog(entry, data),
                  ),
                  IconButton(
                    tooltip: '統合',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.call_merge_outlined),
                    onPressed: _runningAction
                        ? null
                        : () => _showMergeDialog(<TagWithId>[entry], data),
                  ),
                  IconButton(
                    tooltip: '削除',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.delete_outline),
                    onPressed: _runningAction
                        ? null
                        : () => _confirmDelete(<TagWithId>[entry]),
                  ),
                ],
              );

              if (wide) {
                return Row(
                  children: [
                    Checkbox(
                      value: selected,
                      onChanged: _runningAction
                          ? null
                          : (_) => _toggleSelection(entry.tagId),
                    ),
                    const SizedBox(width: 6),
                    SizedBox(
                      width: 108,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: _buildCategoryBadge(entry.tag.category),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(flex: 4, child: infoColumn),
                    const SizedBox(width: 16),
                    SizedBox(width: 180, child: _buildPreviewStrip(summary)),
                    const SizedBox(width: 16),
                    SizedBox(
                      width: 118,
                      child: Text(
                        _formatDateTime(summary.lastUsedAt),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(width: 10),
                    actionRow,
                  ],
                );
              }

              if (medium) {
                return Column(
                  children: [
                    Row(
                      children: [
                        Checkbox(
                          value: selected,
                          onChanged: _runningAction
                              ? null
                              : (_) => _toggleSelection(entry.tagId),
                        ),
                        const SizedBox(width: 6),
                        _buildCategoryBadge(entry.tag.category),
                        const SizedBox(width: 12),
                        Expanded(child: infoColumn),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 110,
                          child: Text(
                            _formatDateTime(summary.lastUsedAt),
                            style: Theme.of(context).textTheme.bodySmall,
                            textAlign: TextAlign.right,
                          ),
                        ),
                        const SizedBox(width: 8),
                        actionRow,
                      ],
                    ),
                    const SizedBox(height: 10),
                    _buildPreviewStrip(summary),
                  ],
                );
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Checkbox(
                        value: selected,
                        onChanged: _runningAction
                            ? null
                            : (_) => _toggleSelection(entry.tagId),
                      ),
                      const SizedBox(width: 6),
                      Expanded(child: _buildCategoryBadge(entry.tag.category)),
                      actionRow,
                    ],
                  ),
                  const SizedBox(height: 4),
                  infoColumn,
                  const SizedBox(height: 10),
                  _buildPreviewStrip(summary),
                  const SizedBox(height: 8),
                  Text(
                    '使用日時: ${_formatDateTime(summary.lastUsedAt)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildCardItem(_ResolvedTagEntry resolved, _TagManagementData data) {
    final entry = resolved.entry;
    final summary = resolved.summary;
    final selected = _selectedTagIds.contains(entry.tagId);

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          if (_selectedTagIds.isNotEmpty) {
            _toggleSelection(entry.tagId);
            return;
          }
          _openTagResults(entry);
        },
        onLongPress: () => _toggleSelection(entry.tagId),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Checkbox(
                    value: selected,
                    onChanged: _runningAction
                        ? null
                        : (_) => _toggleSelection(entry.tagId),
                    visualDensity: VisualDensity.compact,
                  ),
                  const SizedBox(width: 4),
                  Expanded(child: _buildCategoryBadge(entry.tag.category)),
                  _buildCountBadge(summary),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                entry.tag.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                summary.previewItems.isEmpty
                    ? '代表作品なし'
                    : summary.previewItems.first.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              if (resolved.mergeSuggestions.isNotEmpty) ...[
                const SizedBox(height: 8),
                _buildMergeSuggestionChips(resolved, data, maxSuggestions: 2),
              ],
              const SizedBox(height: 10),
              _buildPreviewStrip(summary),
              const Spacer(),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _formatDateTime(summary.lastUsedAt),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  IconButton(
                    tooltip: '編集',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: _runningAction
                        ? null
                        : () => _showRenameDialog(entry, data),
                  ),
                  IconButton(
                    tooltip: '統合',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.call_merge_outlined),
                    onPressed: _runningAction
                        ? null
                        : () => _showMergeDialog(<TagWithId>[entry], data),
                  ),
                  IconButton(
                    tooltip: '削除',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.delete_outline),
                    onPressed: _runningAction
                        ? null
                        : () => _confirmDelete(<TagWithId>[entry]),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSelectionBar(
    List<_ResolvedTagEntry> visibleEntries,
    _TagManagementData data,
  ) {
    final selectedEntries = data.tags
        .where((entry) => _selectedTagIds.contains(entry.tagId))
        .toList(growable: false);
    final canMerge =
        selectedEntries.isNotEmpty &&
        selectedEntries.map((entry) => entry.tag.category).toSet().length == 1;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            '${selectedEntries.length}件選択中',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          OutlinedButton.icon(
            onPressed: _runningAction
                ? null
                : () => _selectVisibleEntries(visibleEntries),
            icon: const Icon(Icons.select_all),
            label: const Text('表示中を選択'),
          ),
          TextButton(
            onPressed: _runningAction ? null : _clearSelection,
            child: const Text('選択解除'),
          ),
          FilledButton.tonalIcon(
            onPressed: _runningAction || !canMerge
                ? null
                : () => _showMergeDialog(selectedEntries, data),
            icon: const Icon(Icons.call_merge),
            label: const Text('一括統合'),
          ),
          FilledButton.icon(
            onPressed: _runningAction || selectedEntries.isEmpty
                ? null
                : () => _confirmDelete(selectedEntries),
            icon: const Icon(Icons.delete_outline),
            label: const Text('一括削除'),
          ),
          if (!canMerge && selectedEntries.isNotEmpty)
            Text(
              '一括統合は同じカテゴリのタグだけ選択できます',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildToolbar(
    _TagManagementData data,
    List<_ResolvedTagEntry> visibleEntries,
  ) {
    final visibleCategoryCounts = _countByCategory(
      visibleEntries.map((entry) => entry.entry),
    );
    final totalCount = data.tags.length;
    final visibleCount = visibleEntries.length;

    Widget categoryChip(TagCategory? category) {
      final label = category == null ? 'すべて' : _categoryLabel(category);
      final total = category == null
          ? totalCount
          : (data.categoryCounts[category] ?? 0);
      final visible = category == null
          ? visibleCount
          : (visibleCategoryCounts[category] ?? 0);
      final selected = _categoryFilter == category;
      final icon = category == null
          ? Icons.grid_view_outlined
          : _categoryIcon(category);

      final text = visible == total
          ? '$label $total'
          : '$label $visible/$total';
      return ChoiceChip(
        selected: selected,
        avatar: Icon(icon, size: 16),
        label: Text(text),
        onSelected: (_) => _setCategoryFilter(category),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 920;
              final searchField = Expanded(
                child: SceneSearchField(
                  controller: _searchController,
                  hintText: 'タグ名で検索',
                  onChanged: _setQuery,
                  onClear: () {
                    _searchController.clear();
                    _setQuery('');
                  },
                ),
              );

              final viewToggle = SegmentedButton<_TagViewMode>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment<_TagViewMode>(
                    value: _TagViewMode.list,
                    icon: Icon(Icons.view_list_outlined),
                    label: Text('リスト'),
                  ),
                  ButtonSegment<_TagViewMode>(
                    value: _TagViewMode.card,
                    icon: Icon(Icons.view_module_outlined),
                    label: Text('カード'),
                  ),
                ],
                selected: <_TagViewMode>{_viewMode},
                onSelectionChanged: _runningAction
                    ? null
                    : (selection) => _setViewMode(selection.first),
              );

              final sortDropdown = DropdownButtonFormField<_TagSortMode>(
                initialValue: _sortMode,
                isDense: true,
                decoration: const InputDecoration(
                  labelText: '並び順',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: const [
                  DropdownMenuItem(
                    value: _TagSortMode.countDesc,
                    child: Text('件数順'),
                  ),
                  DropdownMenuItem(
                    value: _TagSortMode.nameAsc,
                    child: Text('名前順'),
                  ),
                  DropdownMenuItem(
                    value: _TagSortMode.recentDesc,
                    child: Text('使用日時順'),
                  ),
                ],
                onChanged: _runningAction
                    ? null
                    : (value) {
                        if (value != null) {
                          _setSortMode(value);
                        }
                      },
              );

              if (compact) {
                return Column(
                  children: [
                    Row(
                      children: [
                        searchField,
                        const SizedBox(width: 10),
                        IconButton(
                          tooltip: '再読み込み',
                          onPressed: _runningAction ? null : _refresh,
                          icon: const Icon(Icons.refresh),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(child: sortDropdown),
                        const SizedBox(width: 10),
                        viewToggle,
                      ],
                    ),
                  ],
                );
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  searchField,
                  const SizedBox(width: 12),
                  SizedBox(width: 150, child: sortDropdown),
                  const SizedBox(width: 12),
                  viewToggle,
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: '再読み込み',
                    onPressed: _runningAction ? null : _refresh,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  categoryChip(null),
                  const SizedBox(width: 8),
                  for (final category in TagCategory.values) ...[
                    categoryChip(category),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                '表示 $visibleCount / $totalCount タグ',
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 12),
              if (_runningAction)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBody(
    _TagManagementData data,
    List<_ResolvedTagEntry> visibleEntries,
  ) {
    if (visibleEntries.isEmpty) {
      return const SceneEmptyState(
        icon: Icons.sell_outlined,
        title: '一致するタグがありません',
        message: '検索条件、カテゴリ、並び順を見直してください。',
      );
    }

    if (_viewMode == _TagViewMode.card) {
      return GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 360,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          mainAxisExtent: 214,
        ),
        itemCount: visibleEntries.length,
        itemBuilder: (context, index) {
          return _buildCardItem(visibleEntries[index], data);
        },
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      itemCount: visibleEntries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        return _buildListItem(visibleEntries[index], data);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('タグ管理')),
      body: FutureBuilder<_TagManagementData>(
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

          final data = snapshot.data ?? const _TagManagementData.empty();
          final visibleEntries = _resolveEntries(data);

          return Column(
            children: [
              _buildToolbar(data, visibleEntries),
              if (_selectedTagIds.isNotEmpty)
                _buildSelectionBar(visibleEntries, data),
              Expanded(child: _buildBody(data, visibleEntries)),
            ],
          );
        },
      ),
    );
  }
}

class _TagManagementData {
  final List<TagWithId> tags;
  final _TagUsageIndex usageIndex;
  final Map<TagCategory, int> categoryCounts;

  const _TagManagementData({
    required this.tags,
    required this.usageIndex,
    required this.categoryCounts,
  });

  const _TagManagementData.empty()
    : tags = const <TagWithId>[],
      usageIndex = const _TagUsageIndex.empty(),
      categoryCounts = const <TagCategory, int>{};
}

class _ResolvedTagEntry {
  final TagWithId entry;
  final _TagUsageSummary summary;
  final List<TagWithId> mergeSuggestions;

  const _ResolvedTagEntry({
    required this.entry,
    required this.summary,
    required this.mergeSuggestions,
  });
}

class _TagUsageIndex {
  final Map<String, _TagUsageSummary> summaries;

  const _TagUsageIndex({required this.summaries});

  const _TagUsageIndex.empty() : summaries = const <String, _TagUsageSummary>{};

  _TagUsageSummary summaryFor(Tag tag) {
    final key = '${tag.category.name}\u0000${tag.name.trim().toLowerCase()}';
    return summaries[key] ?? const _TagUsageSummary.empty();
  }
}

class _TagUsageSummary {
  final int count;
  final List<MediaItem> previewItems;
  final DateTime? lastUsedAt;

  const _TagUsageSummary({
    required this.count,
    required this.previewItems,
    required this.lastUsedAt,
  });

  const _TagUsageSummary.empty()
    : count = 0,
      previewItems = const <MediaItem>[],
      lastUsedAt = null;
}

class _ScoredMergeCandidate {
  final TagWithId entry;
  final int score;
  final int count;

  const _ScoredMergeCandidate({
    required this.entry,
    required this.score,
    required this.count,
  });
}
