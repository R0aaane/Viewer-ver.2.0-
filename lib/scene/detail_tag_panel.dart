// ignore_for_file: invalid_use_of_protected_member, file_names

part of 'detailImage.dart';

extension _DetailTagPanel on _ImageDetailPageState {
  String? _normalizeTag(String input) {
    return _tagController.normalizeTag(input);
  }

  Future<void> _loadMasterTags({String? contains}) async {
    _masterTagsInitialized = true;
    setState(() => _masterLoading = true);
    try {
      final futures = TagCategory.values.map((category) async {
        final list = await widget.tagService.listTagMasterByCategory(
          category,
          contains: contains,
          limit: 400,
        );
        return MapEntry(category, _sortTagWithIdList(list));
      });
      final loaded = await Future.wait(futures);
      if (!mounted) return;
      setState(() {
        _masterTagsByCategory = <TagCategory, List<TagWithId>>{
          for (final entry in loaded) entry.key: entry.value,
        };
      });
    } finally {
      if (mounted) setState(() => _masterLoading = false);
    }
  }

  void _scheduleMasterTagReload(String rawQuery) {
    _tagController.masterFilterDebounce?.cancel();
    _tagController.masterFilterDebounce = Timer(
      const Duration(milliseconds: 240),
      () {
        final query = rawQuery.trim();
        unawaited(_loadMasterTags(contains: query.isEmpty ? null : query));
      },
    );
  }

  Future<void> _loadRecentTags() async {
    final prefs = await SharedPreferences.getInstance();
    final rawEntries =
        prefs.getStringList(_PrefsKeys.detailRecentTags) ?? const <String>[];
    final decoded = <Tag>[];
    final seen = <String>{};
    for (final raw in rawEntries) {
      final tag = _deserializeRecentTag(raw);
      if (tag == null) {
        continue;
      }
      final key = _tagLookupKey(tag);
      if (key == null || !seen.add(key)) {
        continue;
      }
      decoded.add(tag);
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _recentTags = decoded;
    });
  }

  String _serializeRecentTag(Tag tag) => _tagController.serializeRecentTag(tag);

  Tag? _deserializeRecentTag(String raw) {
    return _tagController.deserializeRecentTag(raw);
  }

  Future<void> _recordRecentTag(Tag tag) async {
    final key = _tagLookupKey(tag);
    if (key == null) {
      return;
    }

    final next = <Tag>[tag];
    for (final existing in _recentTags) {
      final existingKey = _tagLookupKey(existing);
      if (existingKey == null || existingKey == key) {
        continue;
      }
      next.add(existing);
      if (next.length >= 30) {
        break;
      }
    }

    if (mounted) {
      setState(() {
        _recentTags = next;
      });
    } else {
      _recentTags = next;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _PrefsKeys.detailRecentTags,
      next.map(_serializeRecentTag).toList(growable: false),
    );
  }

  Future<void> _loadTagUsageCountsForCurrentFolder() async {
    final scopeRaw = _item.folderRaw;
    _tagUsageScopeRaw = scopeRaw;
    if (mounted) {
      setState(() => _tagUsageLoading = true);
    } else {
      _tagUsageLoading = true;
    }

    try {
      final loaded = await widget.repo.listMediaRecursiveFiles(
        FolderHandle(scopeRaw),
      );
      final items = loaded
          .where((entry) => entry.kind != MediaKind.folder)
          .toList(growable: false);
      if (items.isEmpty) {
        if (!mounted || _tagUsageScopeRaw != scopeRaw) {
          return;
        }
        setState(() {
          _tagUsageCounts = <String, int>{};
        });
        return;
      }

      widget.tagService.rememberItems(items);
      final details = await widget.tagService.getDetailedTagsByItems(items);
      final counts = <String, int>{};
      for (final tags in details.values) {
        final seenInItem = <String>{};
        for (final entry in tags) {
          final key = _tagLookupKey(entry.tag);
          if (key == null || !seenInItem.add(key)) {
            continue;
          }
          counts[key] = (counts[key] ?? 0) + 1;
        }
      }

      if (!mounted || _tagUsageScopeRaw != scopeRaw) {
        return;
      }
      setState(() {
        _tagUsageCounts = counts;
      });
    } catch (_) {
      if (!mounted || _tagUsageScopeRaw != scopeRaw) {
        return;
      }
      setState(() {
        _tagUsageCounts = <String, int>{};
      });
    } finally {
      if (mounted && _tagUsageScopeRaw == scopeRaw) {
        setState(() => _tagUsageLoading = false);
      } else if (_tagUsageScopeRaw == scopeRaw) {
        _tagUsageLoading = false;
      }
    }
  }

  String? _tagLookupKey(Tag tag) {
    return _tagController.tagLookupKey(tag);
  }

  Future<void> _loadTagsForCurrent({
    bool force = false,
    int? loadVersion,
  }) async {
    final item = _item;
    final version = loadVersion ?? _detailLoadVersion;
    if (!force && _loadedTagItemId == item.id) {
      return;
    }

    setState(() {
      _tagsLoading = true;
      if (_loadedTagItemId != item.id) {
        _tags = const [];
      }
    });
    try {
      final list = await widget.tagService.listTagsForItem(item.id, item: item);
      if (!_isCurrentLoad(version, item)) return;
      setState(() {
        _tags = list;
        _loadedTagItemId = item.id;
      });
      if (!_inReader || force) {
        unawaited(_loadRelatedItemsForCurrent(list, version, force: force));
      }
      if (_isKemonoTaggedImage(item, list)) {
        unawaited(_loadKemonoVerticalItems(item, version));
      }
    } finally {
      if (_isCurrentLoad(version, item)) {
        setState(() => _tagsLoading = false);
      }
    }
  }

  Future<void> _loadRelatedItemsForCurrent(
    List<TagWithId> tags,
    int loadVersion, {
    bool force = false,
  }) async {
    final item = _item;
    if (!force && _relatedItemsForItemId == item.id) return;

    final selectedTags = tags
        .map((entry) => entry.tag)
        .where((tag) => tag.name.trim().isNotEmpty)
        .take(6)
        .toList(growable: false);
    if (selectedTags.isEmpty) {
      if (_isCurrentLoad(loadVersion, item)) {
        setState(() {
          _relatedItems = const [];
          _relatedItemsLoading = false;
          _relatedItemsForItemId = item.id;
        });
      }
      return;
    }

    setState(() {
      _relatedItemsLoading = true;
      _relatedItemsForItemId = item.id;
    });
    try {
      final matches = await Future.wait(
        selectedTags.map((tag) {
          if (widget.tagService.isRemoteMode) {
            return widget.tagService.findMediaItemsByTagAcrossFolders(
              category: tag.category,
              name: tag.name,
              repo: widget.repo,
              folderRaws: <String>[item.folderRaw],
            );
          }
          return widget.tagService.findMediaItemsByTagGlobal(
            category: tag.category,
            name: tag.name,
          );
        }),
      );
      if (!_isCurrentLoad(loadVersion, item)) return;
      final scoreById = <String, int>{};
      final itemById = <String, MediaItem>{};
      for (final group in matches) {
        for (final candidate in group) {
          if (candidate.id == item.id || candidate.kind == MediaKind.folder) {
            continue;
          }
          itemById[candidate.id] = candidate;
          scoreById.update(
            candidate.id,
            (score) => score + 1,
            ifAbsent: () => 1,
          );
        }
      }
      final related = itemById.values.toList(growable: true)
        ..sort((left, right) {
          final scoreCompare = (scoreById[right.id] ?? 0).compareTo(
            scoreById[left.id] ?? 0,
          );
          return scoreCompare != 0
              ? scoreCompare
              : left.displayName.compareTo(right.displayName);
        });
      setState(() => _relatedItems = related.take(12).toList(growable: false));
    } catch (_) {
      if (_isCurrentLoad(loadVersion, item)) {
        setState(() => _relatedItems = const []);
      }
    } finally {
      if (_isCurrentLoad(loadVersion, item)) {
        setState(() => _relatedItemsLoading = false);
      }
    }
  }

  Future<void> _addSuggestedTag(Tag tag) async {
    try {
      await widget.tagService.addTagToItem(_item, tag);
      _tagsChanged = true;
      await _recordRecentTag(tag);
      await _loadTagsForCurrent(force: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('タグ追加に失敗しました: $e')));
    }
  }

  Future<void> _addTagFromUi() async {
    final raw = _tagController.tagCtrl.text;
    final name = _normalizeTag(raw);
    if (name == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('タグ名が無効です（空白を含めずに入力してください）')),
      );
      return;
    }

    final tag = Tag(name: name, category: _tagController.selectedCategory);

    try {
      await widget.tagService.addTagToItem(_item, tag);

      _tagsChanged = true;
      await _recordRecentTag(tag);
      _tagController.tagCtrl.clear();
      await _loadTagsForCurrent(force: true);
      unawaited(
        _loadMasterTags(
          contains: _tagController.masterFilterCtrl.text.trim().isEmpty
              ? null
              : _tagController.masterFilterCtrl.text.trim(),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('タグ追加に失敗しました: $e')));
    }
  }

  Future<void> _removeTagFromUi(TagWithId t) async {
    try {
      await widget.tagService.removeTagFromItem(_item.id, t.tagId, item: _item);
      _tagsChanged = true;
      await _loadTagsForCurrent(force: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('タグ削除に失敗しました: $e')));
    }
  }

  Future<void> _openAssignedTagResults(Tag tag) async {
    final scopeRaw = (_folder?.raw.trim().isNotEmpty ?? false)
        ? _folder!.raw
        : _item.folderRaw;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TagResultsPage(
          tagService: widget.tagService,
          repo: widget.repo,
          folderRaws: <String>[scopeRaw],
          category: tag.category,
          tagName: tag.name,
        ),
      ),
    );
  }

  List<TagCategory> get _orderedTagCategories =>
      _tagController.orderedTagCategories;

  int _categoryOrder(TagCategory category) {
    return _tagController.categoryOrder(category);
  }

  String _categoryLabel(TagCategory category) {
    return _tagController.categoryLabel(category);
  }

  String _categoryLongLabel(TagCategory category) {
    return _tagController.categoryLongLabel(category);
  }

  IconData _categoryIcon(TagCategory category) {
    return _tagController.categoryIcon(category);
  }

  Color _categoryColor(TagCategory category) {
    return _tagController.categoryColor(category);
  }

  List<TagWithId> _sortTagWithIdList(Iterable<TagWithId> source) {
    return _tagController.sortTagWithIdList(source);
  }

  List<TagWithId> _filteredAssignedTags() {
    return _tagController.filteredAssignedTags(_tags);
  }

  Map<TagCategory, List<TagWithId>> _groupAssignedTags() {
    return _tagController.groupAssignedTags(_tags);
  }

  int _tagUsageCount(Tag tag) {
    final key = _tagLookupKey(tag);
    if (key == null) {
      return 0;
    }
    return _tagUsageCounts[key] ?? 0;
  }

  bool _matchesMasterFilter(Tag tag) {
    return _tagController.matchesMasterFilter(tag);
  }

  int _tagNameMatchRank(Tag tag) {
    return _tagController.tagNameMatchRank(tag);
  }

  List<_TagSuggestionEntry> _buildSuggestionEntries(_TagSuggestionTab tab) {
    final assignedKeys = _tags
        .map((entry) => _tagLookupKey(entry.tag))
        .whereType<String>()
        .toSet();
    final recentOrder = <String, int>{};
    for (var index = 0; index < _recentTags.length; index++) {
      final key = _tagLookupKey(_recentTags[index]);
      if (key != null && !recentOrder.containsKey(key)) {
        recentOrder[key] = index;
      }
    }

    final deduped = <String, _TagSuggestionEntry>{};

    void addTag(Tag tag) {
      if (!_matchesMasterFilter(tag)) {
        return;
      }
      final key = _tagLookupKey(tag);
      if (key == null || assignedKeys.contains(key)) {
        return;
      }
      final candidate = _TagSuggestionEntry(
        tag: tag,
        usageCount: _tagUsageCount(tag),
        isRecent: recentOrder.containsKey(key),
      );
      final existing = deduped[key];
      if (existing == null ||
          existing.usageCount < candidate.usageCount ||
          (!existing.isRecent && candidate.isRecent)) {
        deduped[key] = candidate;
      }
    }

    for (final category in _orderedTagCategories) {
      final entries = _masterTagsByCategory[category] ?? const <TagWithId>[];
      for (final entry in entries) {
        addTag(entry.tag);
      }
    }
    for (final tag in _recentTags) {
      addTag(tag);
    }

    final allEntries = deduped.values.toList(growable: true);
    final assignedCategories = _tags.map((entry) => entry.tag.category).toSet();

    List<_TagSuggestionEntry> filtered;
    switch (tab) {
      case _TagSuggestionTab.recent:
        filtered = allEntries
            .where((entry) => entry.isRecent)
            .toList(growable: true);
        break;
      case _TagSuggestionTab.all:
        filtered = allEntries;
        break;
      case _TagSuggestionTab.recommended:
        filtered = allEntries
            .where((entry) {
              return entry.isRecent ||
                  entry.usageCount > 0 ||
                  entry.tag.category == _tagController.selectedCategory ||
                  assignedCategories.contains(entry.tag.category);
            })
            .toList(growable: true);
        if (filtered.isEmpty) {
          filtered = allEntries;
        }
        break;
    }

    filtered.sort((left, right) {
      final categoryCompare = _categoryOrder(
        left.tag.category,
      ).compareTo(_categoryOrder(right.tag.category));
      if (categoryCompare != 0) {
        return categoryCompare;
      }

      final matchCompare = _tagNameMatchRank(
        left.tag,
      ).compareTo(_tagNameMatchRank(right.tag));
      if (matchCompare != 0) {
        return matchCompare;
      }

      if (tab == _TagSuggestionTab.recent) {
        final leftRecent = recentOrder[_tagLookupKey(left.tag)] ?? 999999;
        final rightRecent = recentOrder[_tagLookupKey(right.tag)] ?? 999999;
        final recentCompare = leftRecent.compareTo(rightRecent);
        if (recentCompare != 0) {
          return recentCompare;
        }
      } else {
        final leftSelected =
            left.tag.category == _tagController.selectedCategory ? 1 : 0;
        final rightSelected =
            right.tag.category == _tagController.selectedCategory ? 1 : 0;
        final selectedCompare = rightSelected.compareTo(leftSelected);
        if (selectedCompare != 0 && tab == _TagSuggestionTab.recommended) {
          return selectedCompare;
        }

        final leftAssigned = assignedCategories.contains(left.tag.category)
            ? 1
            : 0;
        final rightAssigned = assignedCategories.contains(right.tag.category)
            ? 1
            : 0;
        final assignedCompare = rightAssigned.compareTo(leftAssigned);
        if (assignedCompare != 0 && tab == _TagSuggestionTab.recommended) {
          return assignedCompare;
        }

        final recentCompare = (right.isRecent ? 1 : 0).compareTo(
          left.isRecent ? 1 : 0,
        );
        if (recentCompare != 0 && tab == _TagSuggestionTab.recommended) {
          return recentCompare;
        }

        final usageCompare = right.usageCount.compareTo(left.usageCount);
        if (usageCompare != 0) {
          return usageCompare;
        }
      }

      return left.tag.name.toLowerCase().compareTo(
        right.tag.name.toLowerCase(),
      );
    });
    return filtered;
  }

  Map<TagCategory, List<_TagSuggestionEntry>> _groupSuggestionEntries(
    _TagSuggestionTab tab,
  ) {
    final grouped = <TagCategory, List<_TagSuggestionEntry>>{};
    for (final entry in _buildSuggestionEntries(tab)) {
      grouped
          .putIfAbsent(entry.tag.category, () => <_TagSuggestionEntry>[])
          .add(entry);
    }
    return grouped;
  }

  bool _isGroupExpanded(String key, {required bool defaultValue}) {
    return _tagController.isGroupExpanded(key, defaultValue: defaultValue);
  }

  void _toggleGroupExpanded(String key, {required bool defaultValue}) {
    setState(() {
      _tagController.toggleGroupExpanded(key, defaultValue: defaultValue);
    });
  }

  int _visibleCandidateCount(
    _TagSuggestionTab tab,
    TagCategory category,
    int total,
  ) {
    return _tagController.visibleCandidateCount(
      tab: tab,
      category: category,
      total: total,
    );
  }

  void _showMoreCandidates(_TagSuggestionTab tab, TagCategory category) {
    setState(() {
      _tagController.showMoreCandidates(tab, category);
    });
  }

  List<TagWithId> get _masterTags =>
      _masterTagsByCategory[_tagController.selectedCategory] ??
      const <TagWithId>[];

  Future<void> _addExistingMasterTag(TagWithId tag) {
    return _addSuggestedTag(tag.tag);
  }

  Widget _buildAssignedTagsSection() {
    final grouped = _groupAssignedTags();
    final filteredCount = grouped.values.fold<int>(
      0,
      (sum, entries) => sum + entries.length,
    );

    return _buildTagSectionCard(
      title: '付与済みタグ',
      subtitle: filteredCount == _tags.length
          ? '${_tags.length}件'
          : '$filteredCount / ${_tags.length}件',
      trailing: TextButton.icon(
        onPressed: () {
          setState(() => _tagEditMode = !_tagEditMode);
        },
        icon: Icon(_tagEditMode ? Icons.check : Icons.edit_outlined),
        label: Text(_tagEditMode ? '編集を閉じる' : '編集する'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildTagSearchField(
            controller: _tagController.assignedFilterCtrl,
            hintText: '付与済みタグを探す',
            onChanged: (_) => setState(() {}),
          ),
          if (_tagEditMode) ...[
            const SizedBox(height: 12),
            _buildTagEditToolbar(),
          ],
          if (_tagsLoading) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
          const SizedBox(height: 12),
          if (filteredCount == 0 && !_tagsLoading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                _tags.isEmpty ? 'まだタグは付いていません。' : '検索条件に一致する付与済みタグはありません。',
                style: const TextStyle(color: Colors.white70),
              ),
            )
          else
            Column(
              children: [
                for (final category in _orderedTagCategories)
                  if ((grouped[category] ?? const <TagWithId>[]).isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _buildAssignedCategorySection(
                        category: category,
                        tags: grouped[category]!,
                      ),
                    ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildTagEditToolbar() {
    final categoryField = DropdownButtonFormField<TagCategory>(
      initialValue: _tagController.selectedCategory,
      decoration: const InputDecoration(
        labelText: '追加カテゴリ',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      items: _orderedTagCategories
          .map(
            (category) => DropdownMenuItem<TagCategory>(
              value: category,
              child: Text(_categoryLongLabel(category)),
            ),
          )
          .toList(growable: false),
      onChanged: (value) {
        if (value == null) {
          return;
        }
        setState(() => _tagController.selectedCategory = value);
      },
    );
    final inputField = TextField(
      controller: _tagController.tagCtrl,
      decoration: const InputDecoration(
        hintText: 'タグ名を入力 / 空白は不可',
        isDense: true,
        border: OutlineInputBorder(),
      ),
      onSubmitted: (_) => _addTagFromUi(),
    );
    final addButton = FilledButton.icon(
      onPressed: _addTagFromUi,
      icon: const Icon(Icons.add),
      label: const Text('追加'),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 720;
        final layoutToggle = Wrap(
          spacing: 8,
          children: [
            ChoiceChip(
              label: const Text('チップ'),
              selected: _tagLayoutMode == _TagLayoutMode.chips,
              onSelected: (_) {
                setState(() => _tagLayoutMode = _TagLayoutMode.chips);
              },
            ),
            ChoiceChip(
              label: const Text('リスト'),
              selected: _tagLayoutMode == _TagLayoutMode.list,
              onSelected: (_) {
                setState(() => _tagLayoutMode = _TagLayoutMode.list);
              },
            ),
          ],
        );

        if (narrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              categoryField,
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(child: inputField),
                  const SizedBox(width: 8),
                  addButton,
                ],
              ),
              const SizedBox(height: 10),
              layoutToggle,
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 190, child: categoryField),
            const SizedBox(width: 10),
            Expanded(child: inputField),
            const SizedBox(width: 10),
            addButton,
            const SizedBox(width: 12),
            Flexible(child: layoutToggle),
          ],
        );
      },
    );
  }

  Widget _buildAssignedCategorySection({
    required TagCategory category,
    required List<TagWithId> tags,
  }) {
    final key = 'assigned:${category.name}';
    final expanded = _isGroupExpanded(key, defaultValue: true);
    return _buildCategorySectionShell(
      category: category,
      count: tags.length,
      expanded: expanded,
      onToggle: () => _toggleGroupExpanded(key, defaultValue: true),
      child: _tagLayoutMode == _TagLayoutMode.list
          ? Column(
              children: [
                for (final entry in tags)
                  _buildAssignedListTile(
                    entry,
                    showDivider: entry != tags.last,
                  ),
              ],
            )
          : Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [for (final entry in tags) _buildAssignedChip(entry)],
            ),
    );
  }

  Widget _buildAssignedChip(TagWithId entry) {
    return InputChip(
      label: Text(
        '#${entry.tag.name}',
        style: const TextStyle(color: Colors.white),
      ),
      avatar: Icon(
        _categoryIcon(entry.tag.category),
        size: 16,
        color: _categoryColor(entry.tag.category),
      ),
      backgroundColor: _ImageDetailPageState._uiChip,
      deleteIconColor: Colors.white70,
      onPressed: () => _openAssignedTagResults(entry.tag),
      onDeleted: _tagEditMode ? () => _removeTagFromUi(entry) : null,
    );
  }

  Widget _buildAssignedListTile(TagWithId entry, {required bool showDivider}) {
    final usageCount = _tagUsageCount(entry.tag);
    final tile = ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        radius: 15,
        backgroundColor: _categoryColor(
          entry.tag.category,
        ).withValues(alpha: 0.18),
        child: Icon(
          _categoryIcon(entry.tag.category),
          size: 16,
          color: _categoryColor(entry.tag.category),
        ),
      ),
      title: Text(
        '#${entry.tag.name}',
        style: const TextStyle(color: Colors.white),
      ),
      subtitle: Text(
        usageCount > 0
            ? '${_categoryLongLabel(entry.tag.category)} · $usageCount件'
            : _categoryLongLabel(entry.tag.category),
        style: const TextStyle(color: Colors.white70),
      ),
      onTap: () => _openAssignedTagResults(entry.tag),
      trailing: _tagEditMode
          ? IconButton(
              tooltip: '削除',
              icon: const Icon(Icons.close),
              onPressed: () => _removeTagFromUi(entry),
            )
          : null,
    );
    if (!showDivider) {
      return tile;
    }
    return Column(
      children: [
        tile,
        Divider(color: Colors.white.withValues(alpha: 0.08), height: 1),
      ],
    );
  }

  Widget _buildCandidateTagsSection() {
    final recommendedCount = _buildSuggestionEntries(
      _TagSuggestionTab.recommended,
    ).length;
    final recentCount = _buildSuggestionEntries(
      _TagSuggestionTab.recent,
    ).length;
    final allCount = _buildSuggestionEntries(_TagSuggestionTab.all).length;

    return _buildTagSectionCard(
      title: '候補タグ',
      subtitle: _masterLoading ? '読み込み中...' : '$allCount件',
      trailing: Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (_tagUsageLoading)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          IconButton(
            tooltip: '候補を更新',
            onPressed: () => _loadMasterTags(
              contains: _tagController.masterFilterCtrl.text.trim().isEmpty
                  ? null
                  : _tagController.masterFilterCtrl.text.trim(),
            ),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      child: SizedBox(
        height: _isWideLayout(context) ? 420 : 360,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildTagSearchField(
              controller: _tagController.masterFilterCtrl,
              hintText: '候補タグを探す',
              onChanged: (value) {
                setState(() {});
                _scheduleMasterTagReload(value);
              },
            ),
            const SizedBox(height: 12),
            TabBar(
              controller: _candidateTabController,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                Tab(text: 'おすすめ $recommendedCount'),
                Tab(text: '最近使った $recentCount'),
                Tab(text: 'すべて $allCount'),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: TabBarView(
                controller: _candidateTabController,
                children: [
                  _buildSuggestionTabBody(_TagSuggestionTab.recommended),
                  _buildSuggestionTabBody(_TagSuggestionTab.recent),
                  _buildSuggestionTabBody(_TagSuggestionTab.all),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSuggestionTabBody(_TagSuggestionTab tab) {
    final grouped = _groupSuggestionEntries(tab);
    final totalCount = grouped.values.fold<int>(
      0,
      (sum, entries) => sum + entries.length,
    );
    final scrollController = _candidateScrollControllers[tab]!;

    if (totalCount == 0) {
      return Center(
        child: Text(
          _masterLoading ? '候補を読み込み中です...' : '表示できる候補タグはありません。',
          style: const TextStyle(color: Colors.white70),
        ),
      );
    }

    return Scrollbar(
      controller: scrollController,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: scrollController,
        padding: const EdgeInsets.only(right: 8),
        child: Column(
          children: [
            for (final category in _orderedTagCategories)
              if ((grouped[category] ?? const <_TagSuggestionEntry>[])
                  .isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _buildSuggestionCategorySection(
                    tab: tab,
                    category: category,
                    entries: grouped[category]!,
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _buildSuggestionCategorySection({
    required _TagSuggestionTab tab,
    required TagCategory category,
    required List<_TagSuggestionEntry> entries,
  }) {
    final sectionKey = 'candidate:${tab.name}:${category.name}';
    final expanded = _isGroupExpanded(
      sectionKey,
      defaultValue:
          category == TagCategory.artist ||
          category == TagCategory.free ||
          entries.length <= 8,
    );
    final visibleCount = _visibleCandidateCount(tab, category, entries.length);
    final visibleEntries = entries.take(visibleCount).toList(growable: false);

    return _buildCategorySectionShell(
      category: category,
      count: entries.length,
      expanded: expanded,
      onToggle: () => _toggleGroupExpanded(
        sectionKey,
        defaultValue:
            category == TagCategory.artist ||
            category == TagCategory.free ||
            entries.length <= 8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_tagLayoutMode == _TagLayoutMode.list)
            Column(
              children: [
                for (final entry in visibleEntries)
                  _buildSuggestionListTile(
                    entry,
                    showDivider: entry != visibleEntries.last,
                  ),
              ],
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final entry in visibleEntries) _buildSuggestionChip(entry),
              ],
            ),
          if (entries.length > visibleEntries.length) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _showMoreCandidates(tab, category),
                icon: const Icon(Icons.expand_more),
                label: Text(
                  'もっと見る (${entries.length - visibleEntries.length}件)',
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSuggestionChip(_TagSuggestionEntry entry) {
    final usageCount = entry.usageCount;
    return ActionChip(
      avatar: Icon(
        entry.isRecent ? Icons.history : Icons.add_circle_outline,
        size: 16,
        color: _categoryColor(entry.tag.category),
      ),
      label: Text(
        usageCount > 0
            ? '#${entry.tag.name} · $usageCount'
            : '#${entry.tag.name}',
      ),
      onPressed: () => _addSuggestedTag(entry.tag),
    );
  }

  Widget _buildSuggestionListTile(
    _TagSuggestionEntry entry, {
    required bool showDivider,
  }) {
    final subtitleParts = <String>[
      _categoryLongLabel(entry.tag.category),
      if (entry.usageCount > 0) '${entry.usageCount}件',
      if (entry.isRecent) '最近使った',
    ];
    final tile = ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        radius: 15,
        backgroundColor: _categoryColor(
          entry.tag.category,
        ).withValues(alpha: 0.18),
        child: Icon(
          _categoryIcon(entry.tag.category),
          size: 16,
          color: _categoryColor(entry.tag.category),
        ),
      ),
      title: Text(
        '#${entry.tag.name}',
        style: const TextStyle(color: Colors.white),
      ),
      subtitle: Text(
        subtitleParts.join(' · '),
        style: const TextStyle(color: Colors.white70),
      ),
      trailing: FilledButton.tonalIcon(
        onPressed: () => _addSuggestedTag(entry.tag),
        icon: const Icon(Icons.add),
        label: const Text('追加'),
      ),
    );
    if (!showDivider) {
      return tile;
    }
    return Column(
      children: [
        tile,
        Divider(color: Colors.white.withValues(alpha: 0.08), height: 1),
      ],
    );
  }

  Widget _buildTagSearchField({
    required TextEditingController controller,
    required String hintText,
    required ValueChanged<String> onChanged,
  }) {
    return SizedBox(
      height: 44,
      child: SceneSearchField(
        controller: controller,
        hintText: hintText,
        onChanged: onChanged,
        onClear: () {
          controller.clear();
          onChanged('');
        },
      ),
    );
  }

  Widget _buildTagSectionCard({
    required String title,
    required String subtitle,
    required Widget child,
    Widget? trailing,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: Colors.white70),
                    ),
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 12), trailing],
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }

  Widget _buildCategorySectionShell({
    required TagCategory category,
    required int count,
    required bool expanded,
    required VoidCallback onToggle,
    required Widget child,
  }) {
    final color = _categoryColor(category);
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.02),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(
                children: [
                  Icon(_categoryIcon(category), color: color, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    _categoryLongLabel(category),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '$count',
                      style: TextStyle(
                        color: color,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    color: Colors.white70,
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: child,
            ),
        ],
      ),
    );
  }
}
