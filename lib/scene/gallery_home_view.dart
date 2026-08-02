// ignore_for_file: file_names, invalid_use_of_protected_member

part of 'gridGallery.dart';

class _HomeShelfScroller extends StatefulWidget {
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  const _HomeShelfScroller({
    required this.itemCount,
    required this.itemBuilder,
  });

  @override
  State<_HomeShelfScroller> createState() => _HomeShelfScrollerState();
}

class _HomeShelfScrollerState extends State<_HomeShelfScroller> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 382,
      child: Scrollbar(
        controller: _controller,
        thumbVisibility: true,
        interactive: true,
        child: ListView.separated(
          controller: _controller,
          padding: const EdgeInsets.only(bottom: 14),
          scrollDirection: Axis.horizontal,
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: widget.itemCount,
          separatorBuilder: (_, _) => const SizedBox(width: 10),
          itemBuilder: widget.itemBuilder,
        ),
      ),
    );
  }
}

class _TileShell extends StatelessWidget {
  final bool loading;
  final IconData icon;
  const _TileShell({
    this.loading = false,
    this.icon = Icons.broken_image_outlined,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(10),
      child: Center(
        child: loading ? const CircularProgressIndicator() : Icon(icon),
      ),
    );
  }
}

extension _GalleryHomeView on _GalleryGridPageState {
  Future<Map<String, MediaItem>> _buildHomeItemLookup(
    List<MediaItem> mediaItems,
    Iterable<ReadingProgressEntry> recentProgress, {
    Iterable<String> stableItemIds = const <String>[],
  }) async {
    final itemByVariant = <String, MediaItem>{};
    for (final item in mediaItems) {
      for (final variant in _idVariants(item.id)) {
        itemByVariant.putIfAbsent(variant, () => item);
      }
      final progressLookupKey = _readingProgressLookupKey(
        item.folderRaw,
        item.displayName,
      );
      if (progressLookupKey.isNotEmpty) {
        itemByVariant.putIfAbsent(progressLookupKey, () => item);
      }
    }

    final unresolvedStableIds = <String>{
      ...recentProgress
          .map((entry) => entry.mediaId.trim())
          .where(_looksLikeStableMediaId),
      ...stableItemIds
          .map((entry) => entry.trim())
          .where(_looksLikeStableMediaId),
    }.where((itemId) => !itemByVariant.containsKey(itemId)).toSet();
    if (unresolvedStableIds.isEmpty) {
      return itemByVariant;
    }

    for (final item in mediaItems) {
      try {
        final stableId = (await _homeMediaIdResolver.resolve(item)).stableId;
        itemByVariant.putIfAbsent(stableId, () => item);
        unresolvedStableIds.remove(stableId);
        if (unresolvedStableIds.isEmpty) {
          break;
        }
      } catch (_) {
        continue;
      }
    }

    return itemByVariant;
  }

  List<String> _homeSearchTagsFor(MediaItem item) {
    for (final key in _idVariants(item.id)) {
      final tags = _dbTagsByItemId[key];
      if (tags != null) {
        return tags;
      }
    }
    return const <String>[];
  }

  List<TagWithId> _homeSearchTagDetailsFor(MediaItem item) {
    for (final key in _idVariants(item.id)) {
      final details = _dbTagDetailsByItemId[key];
      if (details != null) {
        return details;
      }
    }
    return const <TagWithId>[];
  }

  bool _homeItemHasReadingProgress(MediaItem item, Set<String> readItemKeys) {
    if (readItemKeys.contains(item.id)) return true;
    for (final variant in _idVariants(item.id)) {
      if (readItemKeys.contains(variant)) return true;
    }
    final lookupKey = _readingProgressLookupKey(
      item.folderRaw,
      item.displayName,
    );
    return lookupKey.isNotEmpty && readItemKeys.contains(lookupKey);
  }

  String _buildHomeSearchCorpusSignature(List<MediaItem> items) {
    var hash = 0x811C9DC5;
    for (final item in items) {
      hash = 0x1fffffff & (hash ^ item.id.hashCode ^ item.displayName.hashCode);
      hash = 0x1fffffff & (hash + item.kind.index + item.folderRaw.hashCode);
    }
    return '${_foldersRaw.length}:$hash:${items.length}';
  }

  Future<List<MediaItem>> _ensureHomeSearchCorpusLoaded() async {
    for (final raw in _foldersRaw) {
      if (_folderItemsCacheRecursive.containsKey(raw)) continue;
      try {
        final list = _filterContentItems(
          await widget.repo.listMediaRecursiveFiles(FolderHandle(raw)),
        );
        _folderItemsCacheRecursive[raw] = list
            .where((item) => item.kind != MediaKind.folder)
            .toList(growable: false);
      } catch (_) {
        _folderItemsCacheRecursive[raw] = const <MediaItem>[];
      }
    }

    final all = <MediaItem>[];
    for (final raw in _foldersRaw) {
      final list = _folderItemsCacheRecursive[raw] ?? const <MediaItem>[];
      all.addAll(list);
    }

    final signature = _buildHomeSearchCorpusSignature(all);
    if (_homeSearchCorpusSignature == signature &&
        _homeSearchCorpus.length == all.length) {
      return _homeSearchCorpus;
    }

    widget.tagService.rememberItems(all);
    final details = await widget.tagService.getDetailedTagsByItems(all);

    final expandedNames = <String, List<String>>{};
    final expandedDetails = <String, List<TagWithId>>{};
    details.forEach((key, value) {
      final names = value
          .map((entry) => entry.tag.name)
          .toList(growable: false);
      for (final variant in _idVariants(key)) {
        expandedNames[variant] = names;
        expandedDetails[variant] = value;
      }
    });

    _homeSearchCorpus = all.toList(growable: false);
    _homeSearchCorpusSignature = signature;
    _dbTagsByItemId = expandedNames;
    _dbTagDetailsByItemId = expandedDetails;
    return _homeSearchCorpus;
  }

  bool _matchHomeQuery(MediaItem item, String qRaw) {
    final q = qRaw.trim().toLowerCase();
    if (q.isEmpty) return true;

    final tokens = q.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
    final name = item.displayName.toLowerCase();
    final tags = _homeSearchTagsFor(
      item,
    ).map((entry) => entry.toLowerCase()).toList(growable: false);
    final detailedTags = _homeSearchTagDetailsFor(item);

    bool matchToken(String t) {
      if (t == 'untagged' || t == '未分類') {
        return detailedTags.isEmpty;
      }
      if (t == 'しおり' || t == 'bookmark' || t == 'bookmarked') {
        return _isBookmarkedReadingItem(item);
      }
      final separator = t.indexOf(':');
      if (separator > 0 && separator < t.length - 1) {
        final key = t.substring(0, separator);
        final value = t.substring(separator + 1);
        final category = _tagCategoryForSearchKey(key);
        if (category != null) {
          return detailedTags.any(
            (tag) =>
                tag.tag.category == category &&
                tag.tag.name.toLowerCase().contains(value),
          );
        }
      }

      if (t.startsWith('#')) {
        final needle = t.substring(1);
        if (needle.isEmpty) return true;
        return tags.any((x) => x.contains(needle));
      }

      return name.contains(t) || tags.any((x) => x.contains(t));
    }

    for (final t in tokens) {
      if (!matchToken(t)) return false;
    }
    return true;
  }

  Future<void> _runHomeSearch({
    bool includeAllWhenEmpty = false,
    bool resetPage = true,
  }) async {
    final q = _homeQuery.trim();
    if (!_repoCapabilities.canRecursiveSearch) {
      if (!mounted) return;
      setState(() {
        _homeSearching = false;
        _homeSearchResults = const [];
        _homeSearchErrorMessage = null;
        if (resetPage) _homeSearchPageIndex = 0;
      });
      return;
    }

    if (q.isEmpty && !includeAllWhenEmpty) {
      if (!mounted) return;
      setState(() {
        _homeSearching = false;
        _homeSearchResults = const [];
        _homeSearchErrorMessage = null;
        if (resetPage) _homeSearchPageIndex = 0;
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      _homeSearching = true;
      _homeSearchErrorMessage = null;
    });

    try {
      final all = await _ensureHomeSearchCorpusLoaded();
      final needsProgressForQuery = q
          .toLowerCase()
          .split(RegExp(r'\s+'))
          .any(
            (token) =>
                token == 'しおり' || token == 'bookmark' || token == 'bookmarked',
          );
      if (needsProgressForQuery) {
        await _refreshCurrentPageReadingProgress(all);
      }
      var filtered = q.isEmpty
          ? all.toList(growable: false)
          : all
                .where((item) => _matchHomeQuery(item, q))
                .toList(growable: false);
      final ratingFilter = _homeRatingFilter;
      if (ratingFilter != null) {
        filtered = filtered
            .where((item) => _ratingForItem(item) == ratingFilter)
            .toList(growable: false);
      }
      if (_sortModeUsesReadingProgress(_homeSearchSortMode)) {
        await _refreshCurrentPageReadingProgress(filtered);
      }
      final sorted = _sortItemsByMode(filtered, sortMode: _homeSearchSortMode);

      if (!mounted) return;
      setState(() {
        _homeSearching = false;
        _homeSearchResults = sorted;
        _homeSearchErrorMessage = null;
        if (resetPage) _homeSearchPageIndex = 0;
      });
    } catch (e, st) {
      _logUiError('home-search', e, st);

      if (!mounted) return;
      setState(() {
        _homeSearching = false;
        _homeSearchResults = const [];
        _homeSearchErrorMessage = '全フォルダ検索でエラーが発生しました: $e';
      });

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('全フォルダ検索でエラー: $e')));
    }
  }

  Future<void> _applyDetailedBrowseSortMode(_SortMode value) async {
    if (_sortModeUsesReadingProgress(value)) {
      await _refreshCurrentPageReadingProgress(_homeSearchResults);
    }
    if (!mounted) return;
    setState(() {
      _homeSearchSortMode = value;
      _homeSearchResults = _sortItemsByMode(
        _homeSearchResults,
        sortMode: _homeSearchSortMode,
      );
      _homeSearchPageIndex = 0;
    });
  }

  Future<void> _openDetailedBrowsePage() async {
    if (!_repoCapabilities.canRecursiveSearch) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('このモードでは詳細ブラウズは未対応です')));
      return;
    }
    if (mounted) {
      setState(() => _page = _MainPage.search);
    } else {
      _page = _MainPage.search;
    }
    await _runHomeSearch(includeAllWhenEmpty: true);
  }

  Future<void> _refreshDetailedBrowseIfNeeded() async {
    if (_homeQuery.trim().isNotEmpty || _page == _MainPage.search) {
      await _runHomeSearch(
        includeAllWhenEmpty: _page == _MainPage.search,
        resetPage: false,
      );
    }
  }

  void _handleHomeSearchTextChanged({
    required String value,
    required bool includeAllWhenEmpty,
  }) {
    setState(() {
      _homeQuery = value;
      _homeSearchPageIndex = 0;
    });

    _homeSearchDebounce?.cancel();
    _homeSearchDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      _runHomeSearch(includeAllWhenEmpty: includeAllWhenEmpty);
    });
  }

  Widget _buildSharedHomeSearchField({
    required bool includeAllWhenEmpty,
    String? hintText,
  }) {
    return RawAutocomplete<String>(
      textEditingController: _homeSearchCtrl,
      focusNode: _homeSearchFocusNode,
      optionsBuilder: (value) => _homeSeriesSuggestions(value.text),
      displayStringForOption: (option) => option,
      onSelected: _replaceHomeSearchCurrentToken,
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        return TextField(
          controller: controller,
          focusNode: focusNode,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: hintText ?? 'タイトル / #タグ / artist:xxx / series:yyy',
            border: const OutlineInputBorder(),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
            suffixIcon: (_homeQuery.trim().isEmpty)
                ? null
                : IconButton(
                    tooltip: 'クリア',
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _homeSearchCtrl.clear();
                      setState(() => _homeQuery = '');
                      _runHomeSearch(includeAllWhenEmpty: includeAllWhenEmpty);
                    },
                  ),
          ),
          textInputAction: TextInputAction.search,
          onTap: () {
            if (_homeSearchCorpusSignature.isEmpty) {
              unawaited(_ensureHomeSearchCorpusLoaded());
            }
          },
          onSubmitted: (_) =>
              _runHomeSearch(includeAllWhenEmpty: includeAllWhenEmpty),
          onChanged: (value) => _handleHomeSearchTextChanged(
            value: value,
            includeAllWhenEmpty: includeAllWhenEmpty,
          ),
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        final values = options.toList(growable: false);
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420, maxHeight: 260),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: values.length,
                itemBuilder: (context, index) {
                  final value = values[index];
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.collections_bookmark_outlined),
                    title: Text(value),
                    onTap: () => onSelected(value),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Iterable<String> _homeSeriesSuggestions(String raw) {
    final token = _homeSearchCurrentToken(raw);
    final lower = token.toLowerCase();
    if (lower.isEmpty) return const <String>[];

    final seriesByKey = <String, String>{};
    for (final details in _dbTagDetailsByItemId.values) {
      for (final entry in details) {
        if (entry.tag.category != TagCategory.series) continue;
        final name = entry.tag.name.trim();
        if (name.isEmpty) continue;
        seriesByKey.putIfAbsent(name.toLowerCase(), () => name);
      }
    }

    if (seriesByKey.isEmpty) return const <String>[];
    final needle = lower.startsWith('series:') ? lower.substring(7) : lower;
    return seriesByKey.values
        .where((name) => name.toLowerCase().contains(needle))
        .take(20)
        .map((name) => 'series:${_quoteHomeSearchValue(name)}');
  }

  String _homeSearchCurrentToken(String raw) {
    final selection = _homeSearchCtrl.selection;
    final caret = selection.isValid ? selection.baseOffset : raw.length;
    final safeCaret = caret.clamp(0, raw.length).toInt();
    final before = raw.substring(0, safeCaret);
    final start = before.lastIndexOf(RegExp(r'\s')) + 1;
    final endMatch = RegExp(r'\s').firstMatch(raw.substring(safeCaret));
    final end = endMatch == null ? raw.length : safeCaret + endMatch.start;
    return raw.substring(start, end);
  }

  void _replaceHomeSearchCurrentToken(String option) {
    final text = _homeSearchCtrl.text;
    final selection = _homeSearchCtrl.selection;
    final caret = selection.isValid ? selection.baseOffset : text.length;
    final safeCaret = caret.clamp(0, text.length).toInt();
    final before = text.substring(0, safeCaret);
    final start = before.lastIndexOf(RegExp(r'\s')) + 1;
    final endMatch = RegExp(r'\s').firstMatch(text.substring(safeCaret));
    final end = endMatch == null ? text.length : safeCaret + endMatch.start;
    final next = '${text.substring(0, start)}$option ${text.substring(end)}';
    _homeSearchCtrl.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + option.length + 1),
    );
    _handleHomeSearchTextChanged(value: next, includeAllWhenEmpty: true);
  }

  String _quoteHomeSearchValue(String value) {
    final escaped = value.replaceAll('"', r'\"');
    return value.contains(RegExp(r'\s')) ? '"$escaped"' : escaped;
  }

  List<String> _homeSearchValuesForCategory(
    MediaItem item,
    TagCategory category,
  ) {
    final values = <String>[];
    final seen = <String>{};
    for (final entry in _homeSearchTagDetailsFor(item)) {
      if (entry.tag.category != category) {
        continue;
      }
      final trimmed = entry.tag.name.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      final key = trimmed.toLowerCase();
      if (seen.add(key)) {
        values.add(trimmed);
      }
    }
    return values;
  }

  String _homeSearchPrimaryValueForCategory(
    MediaItem item,
    TagCategory category, {
    int maxValues = 2,
    String emptyLabel = 'N/A',
  }) {
    final values = _homeSearchValuesForCategory(item, category);
    if (values.isEmpty) {
      return emptyLabel;
    }
    return values.take(maxValues).join(' / ');
  }

  String _formatDetailedBrowseDate(DateTime? value) {
    if (value == null) {
      return '不明';
    }
    final local = value.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '${local.year}/$month/$day $hour:$minute';
  }

  Color _detailedBrowseAccentColor(BuildContext context, MediaItem item) {
    final scheme = Theme.of(context).colorScheme;
    switch (item.kind) {
      case MediaKind.pdf:
        return scheme.primaryContainer;
      case MediaKind.epub:
        return scheme.primaryContainer;
      case MediaKind.image:
        return scheme.tertiaryContainer;
      case MediaKind.folder:
        return scheme.secondaryContainer;
    }
  }

  Color _detailedBrowseAccentTextColor(BuildContext context, MediaItem item) {
    final scheme = Theme.of(context).colorScheme;
    switch (item.kind) {
      case MediaKind.pdf:
        return scheme.onPrimaryContainer;
      case MediaKind.epub:
        return scheme.onPrimaryContainer;
      case MediaKind.image:
        return scheme.onTertiaryContainer;
      case MediaKind.folder:
        return scheme.onSecondaryContainer;
    }
  }

  Widget _buildDetailedBrowseThumb(MediaItem item) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: FutureBuilder<ThumbPair>(
        future: _getMediaThumbPair(item),
        builder: (context, snap) {
          if (snap.hasError) {
            return Container(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              alignment: Alignment.center,
              child: const Icon(Icons.broken_image_outlined),
            );
          }
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
    );
  }

  String _detailedBrowseTileSubtitle(MediaItem item) {
    final artist = _homeSearchPrimaryValueForCategory(
      item,
      TagCategory.artist,
      maxValues: 1,
      emptyLabel: '',
    );
    if (artist.isNotEmpty) {
      return artist;
    }

    final series = _homeSearchPrimaryValueForCategory(
      item,
      TagCategory.series,
      maxValues: 1,
      emptyLabel: '',
    );
    if (series.isNotEmpty) {
      return series;
    }

    return _folderLabelForItem(item);
  }

  Widget _buildDetailedBrowseGridTile(MediaItem item) {
    final theme = Theme.of(context);
    final subtitle = _detailedBrowseTileSubtitle(item);
    final folderLabel = _folderLabelForItem(item);
    final updatedAt = _formatDetailedBrowseDate(
      item.modified ?? _getUpdatedAt(item),
    );
    final isSelected = _selectedIds.contains(item.id);
    final isFavorite = _favorites.contains(item.id);
    final accent = _detailedBrowseAccentColor(context, item);
    final accentText = _detailedBrowseAccentTextColor(context, item);

    return ControllerFocusable(
      debugLabel: 'browse-grid-${item.id}',
      borderRadius: BorderRadius.circular(18),
      onLongPress: () {
        if (!_selectMode) {
          _enterSelectMode(item);
        } else {
          _toggleSelect(item);
        }
      },
      onPressed: () async {
        if (_selectMode) {
          _toggleSelect(item);
          return;
        }
        await _openDetailFromHome(item);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: isSelected
              ? Border.all(color: theme.colorScheme.primary, width: 2)
              : null,
          color: isSelected
              ? theme.colorScheme.primary.withValues(alpha: 0.04)
              : Colors.transparent,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(child: _buildDetailedBrowseThumb(item)),
                  Positioned(
                    top: 8,
                    left: 8,
                    child: item.kind == MediaKind.pdf
                        ? _PdfBadge(label: ItemNameService.kindLabel(item))
                        : const SizedBox.shrink(),
                  ),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: _FavButton(
                      isFavorite: isFavorite,
                      onPressed: () => _toggleFavorite(item),
                    ),
                  ),
                  Positioned(
                    left: 8,
                    right: 8,
                    bottom: 8,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.88),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 5,
                        ),
                        child: Text(
                          folderLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: accentText,
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (isSelected)
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        padding: const EdgeInsets.all(8),
                        alignment: Alignment.topRight,
                        child: const Icon(
                          Icons.check_circle,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _displayTitleForItem(item),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
                height: 1.2,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              updatedAt,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: accent.withValues(alpha: 0.95),
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  int _detailedBrowseTotalPages() {
    if (_homeSearchResults.isEmpty) return 0;
    final pageSize = _GalleryGridPageState._detailedBrowsePageSize;
    return (_homeSearchResults.length + pageSize - 1) ~/ pageSize;
  }

  int _detailedBrowseClampedPageIndex() {
    final totalPages = _detailedBrowseTotalPages();
    if (totalPages <= 1) return 0;
    return _homeSearchPageIndex.clamp(0, totalPages - 1);
  }

  List<MediaItem> _currentDetailedBrowsePageItems() {
    if (_homeSearchResults.isEmpty) return const <MediaItem>[];

    final pageSize = _GalleryGridPageState._detailedBrowsePageSize;
    final pageIndex = _detailedBrowseClampedPageIndex();
    final start = pageIndex * pageSize;
    final end = start + pageSize;

    return _homeSearchResults.sublist(
      start,
      end > _homeSearchResults.length ? _homeSearchResults.length : end,
    );
  }

  Widget _buildDetailedBrowsePager() {
    final pageSize = _GalleryGridPageState._detailedBrowsePageSize;
    if (_homeSearchResults.length <= pageSize) {
      return const SizedBox.shrink();
    }

    final totalPages = _detailedBrowseTotalPages();
    final clamped = _detailedBrowseClampedPageIndex();
    final start = clamped * pageSize + 1;
    final end = ((clamped + 1) * pageSize).clamp(0, _homeSearchResults.length);
    final useDropdown = totalPages > 10;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Row(
        children: [
          Text('$start-$end / ${_homeSearchResults.length}'),
          const Spacer(),
          if (useDropdown)
            DropdownButton<int>(
              value: clamped,
              items: List.generate(
                totalPages,
                (index) => DropdownMenuItem<int>(
                  value: index,
                  child: Text('ページ ${index + 1}'),
                ),
              ),
              onChanged: (value) {
                if (value == null || value == clamped) return;
                setState(() => _homeSearchPageIndex = value);
              },
            )
          else
            Flexible(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: List.generate(totalPages, (index) {
                    final selected = index == clamped;
                    return Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: ChoiceChip(
                        label: Text('${index + 1}'),
                        selected: selected,
                        onSelected: (_) {
                          if (selected) return;
                          setState(() => _homeSearchPageIndex = index);
                        },
                      ),
                    );
                  }),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDetailedBrowseResultsBody() {
    Widget headerCard() {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '詳細ブラウズ',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(
                _homeQuery.trim().isEmpty
                    ? 'キーワードなしでも最近の項目を一覧できます。検索すると作家・シリーズ・タグで絞り込めます。'
                    : '作家・シリーズ・タグを含む詳細カードで、PDF や画像を選びやすく表示します。',
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 44,
                child: _buildSharedHomeSearchField(includeAllWhenEmpty: true),
              ),
              const SizedBox(height: 10),
              LayoutBuilder(
                builder: (context, constraints) {
                  final dropdown = DropdownButton<_SortMode>(
                    value: _homeSearchSortMode,
                    items: const [
                      DropdownMenuItem(
                        value: _SortMode.updatedAt,
                        child: Text('更新日'),
                      ),
                      DropdownMenuItem(
                        value: _SortMode.addedAt,
                        child: Text('追加日'),
                      ),
                      DropdownMenuItem(
                        value: _SortMode.name,
                        child: Text('名前'),
                      ),
                      DropdownMenuItem(
                        value: _SortMode.unreadFirst,
                        child: Text('未読'),
                      ),
                      DropdownMenuItem(
                        value: _SortMode.readFirst,
                        child: Text('既読'),
                      ),
                      DropdownMenuItem(
                        value: _SortMode.bookmarkedFirst,
                        child: Text('しおり'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      unawaited(_applyDetailedBrowseSortMode(value));
                    },
                  );
                  final viewDropdown = DropdownButton<DetailedBrowseViewMode>(
                    value: _detailedBrowseViewMode,
                    items: const [
                      DropdownMenuItem(
                        value: DetailedBrowseViewMode.grid,
                        child: Text('カード'),
                      ),
                      DropdownMenuItem(
                        value: DetailedBrowseViewMode.bookshelf,
                        child: Text('本棚'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      _saveDetailedBrowseViewMode(value);
                    },
                  );
                  final ratingDropdown = DropdownButton<int?>(
                    value: _homeRatingFilter,
                    items: const [
                      DropdownMenuItem<int?>(value: null, child: Text('すべて')),
                      DropdownMenuItem<int?>(value: 5, child: Text('評価5')),
                      DropdownMenuItem<int?>(value: 4, child: Text('評価4')),
                      DropdownMenuItem<int?>(value: 3, child: Text('評価3')),
                    ],
                    onChanged: (value) {
                      setState(() {
                        _homeRatingFilter = value;
                        _homeSearchPageIndex = 0;
                      });
                      _runHomeSearch(includeAllWhenEmpty: true);
                    },
                  );

                  if (constraints.maxWidth < 520) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('表示件数: ${_homeSearchResults.length} 件'),
                        Row(
                          children: [
                            const Text('並び替え'),
                            const SizedBox(width: 8),
                            dropdown,
                            const SizedBox(width: 16),
                            const Text('表示'),
                            const SizedBox(width: 8),
                            viewDropdown,
                          ],
                        ),
                        Row(
                          children: [
                            const Text('評価'),
                            const SizedBox(width: 8),
                            ratingDropdown,
                          ],
                        ),
                      ],
                    );
                  }

                  return Row(
                    children: [
                      Text('表示件数: ${_homeSearchResults.length} 件'),
                      const Spacer(),
                      const Text('並び替え'),
                      const SizedBox(width: 8),
                      dropdown,
                      const SizedBox(width: 16),
                      const Text('表示'),
                      const SizedBox(width: 8),
                      viewDropdown,
                      const SizedBox(width: 16),
                      const Text('評価'),
                      const SizedBox(width: 8),
                      ratingDropdown,
                    ],
                  );
                },
              ),
              if (_homeSearching) ...[
                const SizedBox(height: 10),
                const LinearProgressIndicator(),
              ],
            ],
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        const crossAxisCount = 2;
        final pageItems = _currentDetailedBrowsePageItems();
        final showPager =
            _homeSearchResults.length >
            _GalleryGridPageState._detailedBrowsePageSize;
        final crossSpacing = constraints.maxWidth < 420 ? 8.0 : 12.0;
        final mainSpacing = constraints.maxWidth < 420 ? 14.0 : 18.0;
        final contentWidth = constraints.maxWidth <= 760
            ? (constraints.maxWidth - 24).clamp(0.0, double.infinity).toDouble()
            : 760.0;
        final sidePadding = (constraints.maxWidth - contentWidth) / 2;
        final tileWidth =
            (contentWidth - (crossSpacing * (crossAxisCount - 1))) /
            crossAxisCount;
        final tileHeight = (tileWidth * (4 / 3)) + 84;
        final bookshelfMode =
            _detailedBrowseViewMode == DetailedBrowseViewMode.bookshelf;

        return RefreshIndicator(
          onRefresh: _handlePullToRefresh,
          child: CustomScrollView(
            physics: _refreshScrollPhysics,
            cacheExtent: 400,
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(sidePadding, 12, sidePadding, 12),
                sliver: SliverToBoxAdapter(child: headerCard()),
              ),
              if (_homeSearchErrorMessage != null)
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(sidePadding, 0, sidePadding, 12),
                  sliver: SliverToBoxAdapter(
                    child: _buildErrorBody(
                      title: '詳細ブラウズの読み込みに失敗しました',
                      message: _homeSearchErrorMessage!,
                      onAction: () => _runHomeSearch(includeAllWhenEmpty: true),
                    ),
                  ),
                )
              else if (!_homeSearching && _homeSearchResults.isEmpty)
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(sidePadding, 0, sidePadding, 12),
                  sliver: SliverToBoxAdapter(
                    child: _buildEmptyBody(
                      title: '表示できる項目がありません',
                      message: _homeQuery.trim().isEmpty
                          ? '登録フォルダ内に表示対象の PDF / 画像がありません。'
                          : '別のキーワード、タグ、artist / series 指定を試してください。',
                    ),
                  ),
                )
              else ...[
                if (bookshelfMode) ...[
                  ..._buildDetailedBrowseBookshelfSlivers(
                    pageItems,
                    showPager: showPager,
                  ),
                ] else ...[
                  if (showPager)
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        sidePadding,
                        0,
                        sidePadding,
                        12,
                      ),
                      sliver: SliverToBoxAdapter(
                        child: _buildDetailedBrowsePager(),
                      ),
                    ),
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      sidePadding,
                      0,
                      sidePadding,
                      12,
                    ),
                    sliver: SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: crossAxisCount,
                        mainAxisSpacing: mainSpacing,
                        crossAxisSpacing: crossSpacing,
                        mainAxisExtent: tileHeight,
                      ),
                      delegate: SliverChildBuilderDelegate((context, index) {
                        final item = pageItems[index];
                        return _buildDetailedBrowseGridTile(item);
                      }, childCount: pageItems.length),
                    ),
                  ),
                  if (showPager)
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        sidePadding,
                        0,
                        sidePadding,
                        12,
                      ),
                      sliver: SliverToBoxAdapter(
                        child: _buildDetailedBrowsePager(),
                      ),
                    ),
                ],
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _homeFavThumb(MediaItem item, {bool fill = false}) {
    final thumb = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: FutureBuilder<ThumbPair>(
        future: _getMediaThumbPair(item),
        builder: (context, snap) {
          if (snap.hasError) {
            return Container(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              alignment: Alignment.center,
              child: const Icon(Icons.broken_image_outlined),
            );
          }
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
    );

    if (fill) {
      return thumb;
    }

    return AspectRatio(aspectRatio: 3 / 4, child: thumb);
  }

  bool _isFavoriteItem(MediaItem item) {
    for (final variant in _idVariants(item.id)) {
      if (_favorites.contains(variant)) {
        return true;
      }
      if (_favoriteResolvedIds.contains(variant)) {
        return true;
      }
    }
    return false;
  }

  ReadingProgressEntry? _homeRecentViewEntryForItem(MediaItem item) {
    for (final variant in _idVariants(item.id)) {
      final entry = _homeRecentViewEntriesByItemId[variant];
      if (entry != null) {
        return entry;
      }
    }
    return null;
  }

  DateTime _homeAddedTimestamp(MediaItem item) {
    final updated = item.modified ?? _getUpdatedAt(item);
    if (updated.millisecondsSinceEpoch > 0) {
      return updated;
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  String _formatHomeDateTime(DateTime? value) {
    if (value == null || value.millisecondsSinceEpoch <= 0) {
      return '日時未取得';
    }
    final local = value.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '${local.year}/$month/$day $hour:$minute';
  }

  Future<List<MediaItem>> _ensureHomeShelfCorpusLoaded() async {
    if (_repoCapabilities.canRecursiveSearch) {
      return _ensureHomeSearchCorpusLoaded();
    }

    for (final raw in _foldersRaw) {
      if (_folderItemsCache.containsKey(raw)) {
        continue;
      }
      try {
        _folderItemsCache[raw] = _filterContentItems(
          await widget.repo.listMedia(FolderHandle(raw)),
        );
      } catch (_) {
        _folderItemsCache[raw] = const <MediaItem>[];
      }
    }

    final all = <MediaItem>[];
    for (final raw in _foldersRaw) {
      final items = _folderItemsCache[raw] ?? const <MediaItem>[];
      all.addAll(items.where((item) => item.kind != MediaKind.folder));
    }

    final signature = _buildHomeSearchCorpusSignature(all);
    if (_homeSearchCorpusSignature == signature &&
        _homeSearchCorpus.length == all.length) {
      return _homeSearchCorpus;
    }

    widget.tagService.rememberItems(all);
    final details = await widget.tagService.getDetailedTagsByItems(all);

    final expandedNames = <String, List<String>>{};
    final expandedDetails = <String, List<TagWithId>>{};
    details.forEach((key, value) {
      final names = value
          .map((entry) => entry.tag.name)
          .toList(growable: false);
      for (final variant in _idVariants(key)) {
        expandedNames[variant] = names;
        expandedDetails[variant] = value;
      }
    });

    _homeSearchCorpus = all.toList(growable: false);
    _homeSearchCorpusSignature = signature;
    _dbTagsByItemId = expandedNames;
    _dbTagDetailsByItemId = expandedDetails;
    return _homeSearchCorpus;
  }

  Future<void> _refreshHomeShowcases() async {
    final loadVersion = ++_homeShowcaseLoadVersion;
    final sw = Stopwatch()..start();
    debugPrint('[home-refresh] start version=$loadVersion');
    if (mounted) {
      setState(() {
        _homeShowcaseLoading = true;
        _homeShowcaseErrorMessage = null;
      });
    } else {
      _homeShowcaseLoading = true;
      _homeShowcaseErrorMessage = null;
    }
    await SchedulerBinding.instance.endOfFrame;

    try {
      if (_foldersRaw.isEmpty) {
        if (!mounted || loadVersion != _homeShowcaseLoadVersion) {
          return;
        }
        setState(() {
          _homeRecentAddedItems = const <MediaItem>[];
          _homeUnreadItems = const <MediaItem>[];
          _homeFavoriteShowcaseItems = const <MediaItem>[];
          _homeRatingShelfItems = const <MediaItem>[];
          _homeRecentViewedItems = const <MediaItem>[];
          _homeBookmarkedReadingItems = const <MediaItem>[];
          _homeRecentViewEntriesByItemId = <String, ReadingProgressEntry>{};
          _homeResumeCard = null;
          _homeShowcaseErrorMessage = null;
        });
        return;
      }

      final fetchSw = Stopwatch()..start();
      debugPrint('[home-refresh] remote API fetch start');
      final recentProgress = await _readingProgressService.fetchRecent(
        limit: 5000,
      );
      debugPrint(
        '[home-refresh] remote API fetch end ${fetchSw.elapsedMilliseconds}ms',
      );

      final corpusSw = Stopwatch()..start();
      final allItems = await _ensureHomeShelfCorpusLoaded();
      debugPrint(
        '[home-refresh] home corpus load end ${corpusSw.elapsedMilliseconds}ms',
      );
      final mediaItems = allItems
          .where((item) => item.kind != MediaKind.folder)
          .toList(growable: false);

      final buildSw = Stopwatch()..start();
      final addedTimestampByItem = <MediaItem, DateTime>{
        for (final item in mediaItems) item: _homeAddedTimestamp(item),
      };
      int compareHomeAddedDesc(MediaItem a, MediaItem b) {
        return addedTimestampByItem[b]!.compareTo(addedTimestampByItem[a]!);
      }

      final recentAdded = mediaItems.toList(growable: true)
        ..sort(compareHomeAddedDesc);

      final ratingIds = _ratingsById.entries
          .where((entry) => entry.value == _homeRatingShelfRating)
          .map((entry) => entry.key);
      final itemByVariant = await _buildHomeItemLookup(
        mediaItems,
        recentProgress,
        stableItemIds: ratingIds,
      );

      final recentViewedItems = <MediaItem>[];
      final bookmarkedReadingItems = <MediaItem>[];
      final recentViewEntriesByItemId = <String, ReadingProgressEntry>{};
      final readItemKeys = <String>{};
      _HomeResumeCardData? resumeCard;

      for (final entry in recentProgress) {
        final resolved =
            itemByVariant[entry.mediaId] ??
            itemByVariant[_readingProgressLookupKey(
              entry.folderRaw,
              entry.title,
            )];
        if (resolved == null) {
          continue;
        }

        if (!recentViewEntriesByItemId.containsKey(resolved.id)) {
          recentViewedItems.add(resolved);
        }
        recentViewEntriesByItemId[resolved.id] = entry;
        readItemKeys.add(resolved.id);
        readItemKeys.add(entry.mediaId);
        for (final variant in _idVariants(resolved.id)) {
          recentViewEntriesByItemId[variant] = entry;
          readItemKeys.add(variant);
        }
        final lookupKey = _readingProgressLookupKey(
          resolved.folderRaw,
          resolved.displayName,
        );
        if (lookupKey.isNotEmpty) {
          recentViewEntriesByItemId[lookupKey] = entry;
          readItemKeys.add(lookupKey);
        }
        if (entry.isBookmarked &&
            resolved.kind == MediaKind.pdf &&
            ReadingProgressService.shouldShowContinueCard(entry)) {
          bookmarkedReadingItems.add(resolved);
        }

        if (resumeCard == null &&
            resolved.kind == MediaKind.pdf &&
            ReadingProgressService.shouldShowContinueCard(entry)) {
          resumeCard = _HomeResumeCardData(item: resolved, progress: entry);
        }
      }

      final favorites = mediaItems.where(_isFavoriteItem).toList(growable: true)
        ..sort(compareHomeAddedDesc);
      final ratingItemById = <String, MediaItem>{};
      for (final item in mediaItems) {
        if (_ratingForItem(item) == _homeRatingShelfRating) {
          ratingItemById.putIfAbsent(item.id, () => item);
        }
      }
      for (final id in ratingIds) {
        final item = itemByVariant[id];
        if (item != null) {
          ratingItemById.putIfAbsent(item.id, () => item);
        }
      }
      final ratingItems = ratingItemById.values.toList(growable: true)
        ..sort(compareHomeAddedDesc);
      final unreadItems = recentAdded
          .where(
            (item) =>
                item.kind == MediaKind.pdf &&
                !_homeItemHasReadingProgress(item, readItemKeys),
          )
          .toList(growable: false);
      debugPrint(
        '[home-refresh] list build end ${buildSw.elapsedMilliseconds}ms',
      );

      if (!mounted || loadVersion != _homeShowcaseLoadVersion) {
        return;
      }

      setState(() {
        _homeRecentAddedItems = recentAdded.take(10).toList(growable: false);
        _homeUnreadItems = unreadItems.take(10).toList(growable: false);
        _homeFavoriteShowcaseItems = favorites.take(10).toList(growable: false);
        _homeRatingShelfItems = ratingItems.take(10).toList(growable: false);
        _homeRecentViewedItems = recentViewedItems
            .take(10)
            .toList(growable: false);
        _homeBookmarkedReadingItems = bookmarkedReadingItems
            .take(10)
            .toList(growable: false);
        _homeRecentViewEntriesByItemId = recentViewEntriesByItemId;
        _homeResumeCard = resumeCard;
        _homeShowcaseErrorMessage = null;
      });
    } catch (error, stackTrace) {
      _logUiError('home-showcases', error, stackTrace);
      if (!mounted || loadVersion != _homeShowcaseLoadVersion) {
        return;
      }
      setState(() {
        _homeShowcaseErrorMessage = 'ホーム情報の更新に失敗しました: $error';
      });
    } finally {
      if (mounted && loadVersion == _homeShowcaseLoadVersion) {
        setState(() => _homeShowcaseLoading = false);
      } else if (loadVersion == _homeShowcaseLoadVersion) {
        _homeShowcaseLoading = false;
      }
      if (loadVersion == _homeShowcaseLoadVersion) {
        debugPrint('[home-refresh] end ${sw.elapsedMilliseconds}ms');
      }
    }
  }

  void _refreshHomeShowcasesAfterFrame(String reason) {
    debugPrint('[home-refresh] scheduled reason=$reason');
    if (mounted) {
      setState(() {
        _homeShowcaseLoading = true;
        _homeShowcaseErrorMessage = null;
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_refreshHomeShowcases());
    });
  }

  Widget _buildHomeRefreshBanner() {
    if (!_homeShowcaseLoading) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 10),
              Expanded(child: Text('ホームを更新中...')),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHomeSectionHeading(String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: Colors.white70),
        ),
      ],
    );
  }

  Widget _buildHomeShelfMetaLine(String label, String value) {
    return Text(
      '$label: $value',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(
        context,
      ).textTheme.bodySmall?.copyWith(color: Colors.white70),
    );
  }

  Widget _buildHomeShelfEmptyState({
    required IconData icon,
    required String title,
    required String message,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      child: Row(
        children: [
          Icon(icon, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Colors.white70),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHomeMediaShelfCard({
    required MediaItem item,
    required String footerText,
    required IconData footerIcon,
    required VoidCallback onTap,
    String? badgeText,
    IconData? badgeIcon,
    Color? badgeBackgroundColor,
    Color? badgeForegroundColor,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final artist = _homeSearchPrimaryValueForCategory(
      item,
      TagCategory.artist,
      maxValues: 1,
      emptyLabel: '未設定',
    );
    final series = _homeSearchPrimaryValueForCategory(
      item,
      TagCategory.series,
      maxValues: 1,
      emptyLabel: '未設定',
    );
    final width = MediaQuery.of(context).size.width < 560 ? 168.0 : 188.0;

    return SizedBox(
      width: width,
      child: Card(
        clipBehavior: Clip.antiAlias,
        margin: EdgeInsets.zero,
        child: ControllerFocusable(
          debugLabel: 'home-shelf-${item.id}',
          borderRadius: BorderRadius.circular(14),
          onPressed: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _homeFavThumb(item, fill: true),
                      Positioned(
                        left: 8,
                        top: 8,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: _detailedBrowseAccentColor(context, item),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            child: Text(
                              item.kind == MediaKind.pdf ? 'PDF' : '画像',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: _detailedBrowseAccentTextColor(
                                  context,
                                  item,
                                ),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (badgeText != null && badgeText.trim().isNotEmpty)
                        Positioned(
                          right: 8,
                          top: 8,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color:
                                  badgeBackgroundColor ??
                                  scheme.primaryContainer,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (badgeIcon != null) ...[
                                    Icon(
                                      badgeIcon,
                                      size: 12,
                                      color:
                                          badgeForegroundColor ??
                                          scheme.onPrimaryContainer,
                                    ),
                                    const SizedBox(width: 4),
                                  ],
                                  Text(
                                    badgeText,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color:
                                          badgeForegroundColor ??
                                          scheme.onPrimaryContainer,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _displayTitleForItem(item),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                _buildHomeShelfMetaLine('作者', artist),
                const SizedBox(height: 4),
                _buildHomeShelfMetaLine('シリーズ', series),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(footerIcon, size: 14, color: Colors.white70),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        footerText,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.white70,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHomeMediaShelf({
    required String title,
    required String subtitle,
    required List<MediaItem> items,
    required String emptyTitle,
    required String emptyMessage,
    required Widget Function(MediaItem item) itemBuilder,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHomeSectionHeading(title, subtitle),
            const SizedBox(height: 10),
            if (_homeShowcaseLoading && items.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (items.isEmpty)
              _buildHomeShelfEmptyState(
                icon: Icons.photo_library_outlined,
                title: emptyTitle,
                message: emptyMessage,
              )
            else
              _HomeShelfScroller(
                itemCount: items.length,
                itemBuilder: (context, index) => itemBuilder(items[index]),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildHomeRatingShelf() {
    final rating = _homeRatingShelfRating;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: _buildHomeSectionHeading('評価別', '選択した評価の作品を表示します。'),
                ),
                DropdownButton<int>(
                  value: rating,
                  items: const [
                    DropdownMenuItem(value: 5, child: Text('評価5')),
                    DropdownMenuItem(value: 4, child: Text('評価4')),
                    DropdownMenuItem(value: 3, child: Text('評価3')),
                  ],
                  onChanged: (value) {
                    if (value == null || value == _homeRatingShelfRating) {
                      return;
                    }
                    setState(() => _homeRatingShelfRating = value);
                    unawaited(_refreshHomeShowcases());
                  },
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (_homeShowcaseLoading && _homeRatingShelfItems.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_homeRatingShelfItems.isEmpty)
              _buildHomeShelfEmptyState(
                icon: Icons.star_border_rounded,
                title: '評価$ratingの作品はまだありません',
                message: '詳細画面で評価$ratingを付けるとここに表示されます。',
              )
            else
              _HomeShelfScroller(
                itemCount: _homeRatingShelfItems.length,
                itemBuilder: (context, index) {
                  final item = _homeRatingShelfItems[index];
                  return _buildHomeMediaShelfCard(
                    item: item,
                    footerText:
                        '追加 ${_formatHomeDateTime(_homeAddedTimestamp(item))}',
                    footerIcon: Icons.schedule_outlined,
                    badgeText: '評価$rating',
                    badgeIcon: Icons.star_rounded,
                    badgeBackgroundColor: Theme.of(
                      context,
                    ).colorScheme.secondaryContainer,
                    badgeForegroundColor: Theme.of(
                      context,
                    ).colorScheme.onSecondaryContainer,
                    onTap: () => _openDetailFromHome(item),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildContinueReadingCard() {
    final resume = _homeResumeCard;
    if (resume == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHomeSectionHeading('続きから読む', '前回見ていた PDF をそのページから開けます。'),
              const SizedBox(height: 10),
              _buildHomeShelfEmptyState(
                icon: Icons.auto_stories_outlined,
                title: '再開できる PDF がありません',
                message: 'PDF を開いてページを進めると、ここから続きが再開できます。',
              ),
            ],
          ),
        ),
      );
    }

    final item = resume.item;
    final progress = resume.progress;
    final page = progress.currentPage;
    final totalPages = progress.totalPages;
    final pageText = totalPages != null ? 'p.$page / $totalPages' : 'p.$page';
    final progressText = '${(progress.progress * 100).round()}%';
    final artist = _homeSearchPrimaryValueForCategory(
      item,
      TagCategory.artist,
      maxValues: 1,
      emptyLabel: '未設定',
    );
    final series = _homeSearchPrimaryValueForCategory(
      item,
      TagCategory.series,
      maxValues: 1,
      emptyLabel: '未設定',
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHomeSectionHeading('続きから読む', '最後に見ていた PDF をワンタップで再開できます。'),
            const SizedBox(height: 10),
            ControllerFocusable(
              debugLabel: 'continue-reading-${item.id}',
              borderRadius: BorderRadius.circular(14),
              onPressed: () => _openDetailFromHome(item, initialPdfPage: page),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final narrow = constraints.maxWidth < 600;
                    final thumb = SizedBox(
                      width: narrow ? 112 : 132,
                      child: _homeFavThumb(item),
                    );
                    final body = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${_displayTitleForItem(item)} p.$page から再開',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 8),
                        _buildHomeShelfMetaLine('作者', artist),
                        const SizedBox(height: 4),
                        _buildHomeShelfMetaLine('シリーズ', series),
                        const SizedBox(height: 4),
                        _buildHomeShelfMetaLine(
                          '前回閲覧',
                          _formatHomeDateTime(progress.lastReadAt),
                        ),
                        const SizedBox(height: 4),
                        _buildHomeShelfMetaLine(
                          '進捗',
                          '$pageText / $progressText',
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: () =>
                              _openDetailFromHome(item, initialPdfPage: page),
                          icon: const Icon(Icons.play_arrow_rounded),
                          label: Text('$pageText から開く'),
                        ),
                      ],
                    );

                    if (narrow) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [thumb, const SizedBox(height: 12), body],
                      );
                    }

                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        thumb,
                        const SizedBox(width: 14),
                        Expanded(child: body),
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHomeBody() {
    if (_initializing) {
      return _buildRefreshableStatusBody(
        onRefresh: _handlePullToRefresh,
        child: _buildLoadingBody(
          title: 'ホームを読み込み中',
          message: '登録フォルダやホーム用の一覧を準備しています。',
        ),
      );
    }

    if (_initializationErrorMessage != null) {
      return _buildRefreshableStatusBody(
        onRefresh: _handlePullToRefresh,
        child: _buildErrorBody(
          title: 'ホームの初期化に失敗しました',
          message: _initializationErrorMessage!,
          onAction: _retryInitialization,
        ),
      );
    }

    final folderCount = _foldersRaw.length;
    final currentLabel = _currentFolderRaw == null
        ? '未選択'
        : _folderLabel(_currentFolderRaw!);
    final homeSearchPreview = _homeSearchResults
        .take(4)
        .toList(growable: false);
    final recentViewedEntries = _homeRecentViewEntriesByItemId;

    return RefreshIndicator(
      onRefresh: _handlePullToRefresh,
      child: ListView(
        physics: _refreshScrollPhysics,
        padding: const EdgeInsets.all(12),
        children: [
          _buildHomeRefreshBanner(),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'ホーム検索',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 44,
                    child: _buildSharedHomeSearchField(
                      includeAllWhenEmpty: false,
                    ),
                  ),
                  const SizedBox(height: 10),

                  if (_homeSearching)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: CircularProgressIndicator(),
                      ),
                    )
                  else if (!_repoCapabilities.canRecursiveSearch)
                    const Text('このモードでは全フォルダ検索は利用できません。')
                  else if (_homeSearchErrorMessage != null)
                    Text(
                      _homeSearchErrorMessage!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    )
                  else if (_homeQuery.trim().isEmpty)
                    const Text('タイトル、タグ、作者、シリーズで検索できます。')
                  else if (_homeSearchResults.isEmpty)
                    const Text('一致する作品はありません。')
                  else ...[
                    Text('件数: ${_homeSearchResults.length} 件'),
                    const SizedBox(height: 8),
                    ...homeSearchPreview.map((item) {
                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 6),
                        child: ControllerFocusable(
                          debugLabel: 'home-search-${item.id}',
                          borderRadius: BorderRadius.circular(14),
                          onPressed: () => _openDetailFromHome(item),
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  height: 96,
                                  child: _homeFavThumb(item),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _displayTitleForItem(item),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleMedium,
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        item.kind == MediaKind.pdf
                                            ? 'PDF'
                                            : '画像',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall,
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        'フォルダ: ${_folderLabelForItem(item)}',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }),
                    if (_homeSearchResults.length > homeSearchPreview.length)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: OutlinedButton.icon(
                            onPressed: () => _openDetailedBrowsePage(),
                            icon: const Icon(Icons.view_agenda_outlined),
                            label: const Text('詳細ブラウズで続きを見る'),
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'ライブラリ',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text('登録フォルダ数: $folderCount'),
                  Text('現在のフォルダ: $currentLabel'),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ElevatedButton.icon(
                        onPressed: _addFolder,
                        icon: Icon(_primaryAddActionIcon),
                        label: Text(_primaryAddActionLabel),
                      ),
                      OutlinedButton.icon(
                        onPressed: (_currentFolderRaw == null)
                            ? null
                            : () => setState(() => _page = _MainPage.gallery),
                        icon: const Icon(Icons.grid_view),
                        label: const Text('ギャラリーを開く'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _repoCapabilities.canRecursiveSearch
                            ? () => _openDetailedBrowsePage()
                            : null,
                        icon: const Icon(Icons.view_agenda_outlined),
                        label: const Text('詳細ブラウズ'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _refreshAllFavoritesItems,
                        icon: const Icon(Icons.star),
                        label: const Text('お気に入り更新'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (_homeShowcaseErrorMessage != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _homeShowcaseErrorMessage!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (_homeShowcaseErrorMessage != null) const SizedBox(height: 12),
          _buildHomeMediaShelf(
            title: 'お気に入り',
            subtitle: 'お気に入り登録した作品をすぐ開けます。',
            items: _homeFavoriteShowcaseItems,
            emptyTitle: 'お気に入りはまだありません',
            emptyMessage: '作品をお気に入りにすると、ここへ表紙つきで並びます。',
            itemBuilder: (item) {
              final activity = _homeRecentViewEntryForItem(item);
              return _buildHomeMediaShelfCard(
                item: item,
                footerText: activity == null
                    ? '追加 ${_formatHomeDateTime(_homeAddedTimestamp(item))}'
                    : '最終閲覧 ${_formatHomeDateTime(activity.lastReadAt)}',
                footerIcon: activity == null
                    ? Icons.schedule_outlined
                    : Icons.history,
                badgeText: 'お気に入り',
                badgeIcon: Icons.star_rounded,
                badgeBackgroundColor: Theme.of(
                  context,
                ).colorScheme.primaryContainer,
                badgeForegroundColor: Theme.of(
                  context,
                ).colorScheme.onPrimaryContainer,
                onTap: () => _openDetailFromHome(item),
              );
            },
          ),
          const SizedBox(height: 12),
          _buildHomeRatingShelf(),
          const SizedBox(height: 12),
          _buildHomeMediaShelf(
            title: '最近追加',
            subtitle: '追加された作品を表紙つきで一覧できます。',
            items: _homeRecentAddedItems,
            emptyTitle: '最近追加はまだありません',
            emptyMessage: '作品が追加されると、ここに新着が並びます。',
            itemBuilder: (item) => _buildHomeMediaShelfCard(
              item: item,
              footerText:
                  '追加 ${_formatHomeDateTime(_homeAddedTimestamp(item))}',
              footerIcon: Icons.schedule_outlined,
              onTap: () => _openDetailFromHome(item),
            ),
          ),
          const SizedBox(height: 12),
          _buildHomeMediaShelf(
            title: '未読',
            subtitle: 'まだ開いていない PDF を最近追加の順に表示します。',
            items: _homeUnreadItems,
            emptyTitle: '未読の PDF はありません',
            emptyMessage: '未読の PDF があると、ここに表示されます。',
            itemBuilder: (item) => _buildHomeMediaShelfCard(
              item: item,
              footerText:
                  '追加 ${_formatHomeDateTime(_homeAddedTimestamp(item))}',
              footerIcon: Icons.mark_email_unread_outlined,
              badgeText: '未読',
              badgeIcon: Icons.mark_email_unread_outlined,
              badgeBackgroundColor: Theme.of(
                context,
              ).colorScheme.tertiaryContainer,
              badgeForegroundColor: Theme.of(
                context,
              ).colorScheme.onTertiaryContainer,
              onTap: () => _openDetailFromHome(item),
            ),
          ),
          const SizedBox(height: 12),
          _buildContinueReadingCard(),
          const SizedBox(height: 12),
          _buildHomeMediaShelf(
            title: 'しおり',
            subtitle: 'しおりを挟んだ読みかけの PDF を表示します。',
            items: _homeBookmarkedReadingItems,
            emptyTitle: 'しおり付きの読みかけ PDF はありません',
            emptyMessage: '詳細ページでしおりを挟むと、ここに表示されます。',
            itemBuilder: (item) {
              final activity = recentViewedEntries[item.id];
              final page = activity?.currentPage;
              final totalPages = activity?.totalPages;
              final pageText = page == null
                  ? null
                  : totalPages != null
                  ? 'p.$page / $totalPages'
                  : 'p.$page';
              return _buildHomeMediaShelfCard(
                item: item,
                footerText: pageText != null
                    ? 'しおり ${_formatHomeDateTime(activity?.updatedAt)} / $pageText'
                    : 'しおり ${_formatHomeDateTime(activity?.updatedAt)}',
                footerIcon: Icons.bookmark,
                badgeText: pageText ?? 'しおり',
                badgeIcon: Icons.bookmark,
                badgeBackgroundColor: Theme.of(
                  context,
                ).colorScheme.primaryContainer,
                badgeForegroundColor: Theme.of(
                  context,
                ).colorScheme.onPrimaryContainer,
                onTap: () => _openDetailFromHome(
                  item,
                  initialPdfPage: item.kind == MediaKind.pdf && page != null
                      ? page
                      : 1,
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          _buildHomeMediaShelf(
            title: '最近閲覧',
            subtitle: 'さっき見ていた作品へすぐ戻れます。',
            items: _homeRecentViewedItems,
            emptyTitle: '最近閲覧はまだありません',
            emptyMessage: '作品を開くと、ここに最近見たものが並びます。',
            itemBuilder: (item) {
              final activity = recentViewedEntries[item.id];
              final page = activity?.currentPage;
              final totalPages = activity?.totalPages;
              final pageText = page == null
                  ? null
                  : totalPages != null
                  ? 'p.$page / $totalPages'
                  : 'p.$page';
              final progressText = activity == null
                  ? null
                  : '${(activity.progress * 100).round()}%';
              return _buildHomeMediaShelfCard(
                item: item,
                footerText: pageText != null
                    ? '最終閲覧 ${_formatHomeDateTime(activity?.lastReadAt)} / $pageText / $progressText'
                    : '最終閲覧 ${_formatHomeDateTime(activity?.lastReadAt)}',
                footerIcon: Icons.history,
                badgeText: pageText,
                badgeIcon: pageText != null
                    ? Icons.auto_stories_outlined
                    : null,
                badgeBackgroundColor: Theme.of(
                  context,
                ).colorScheme.secondaryContainer,
                badgeForegroundColor: Theme.of(
                  context,
                ).colorScheme.onSecondaryContainer,
                onTap: () => _openDetailFromHome(
                  item,
                  initialPdfPage: item.kind == MediaKind.pdf && page != null
                      ? page
                      : 1,
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '登録フォルダ',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  if (_foldersRaw.isEmpty)
                    Text('登録フォルダがありません。「$_primaryAddActionLabel」から追加してください。')
                  else
                    ..._foldersRaw.map((raw) {
                      final isCurrent = raw == _currentFolderRaw;
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          isCurrent ? Icons.folder : Icons.folder_outlined,
                        ),
                        title: Text(
                          _folderLabel(raw),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          raw,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: '名前変更',
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () => _renameFolder(raw),
                            ),
                            IconButton(
                              tooltip: '削除',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _removeFolder(raw),
                            ),
                          ],
                        ),
                        onTap: () async {
                          await _switchFolder(raw);
                          _exitSelectMode();
                          setState(() => _page = _MainPage.gallery);
                        },
                      );
                    }),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHomeSearchGalleryBody() {
    if (_initializing) {
      return _buildRefreshableStatusBody(
        onRefresh: _handlePullToRefresh,
        child: _buildLoadingBody(
          title: '検索の準備中です',
          message: '設定とフォルダ情報を読み込んでいます。',
        ),
      );
    }

    if (_initializationErrorMessage != null) {
      return _buildRefreshableStatusBody(
        onRefresh: _handlePullToRefresh,
        child: _buildErrorBody(
          title: '初期化に失敗しました',
          message: _initializationErrorMessage!,
          onAction: _retryInitialization,
        ),
      );
    }

    if (!_repoCapabilities.canRecursiveSearch) {
      return _buildRefreshableStatusBody(
        onRefresh: _handlePullToRefresh,
        child: _buildEmptyBody(
          title: '全フォルダ検索は利用できません',
          message: 'このモードでは現在のフォルダ内の表示だけが利用できます。',
        ),
      );
    }

    if (!_homeSearching &&
        _homeSearchCorpusSignature.isEmpty &&
        _homeSearchErrorMessage == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _page != _MainPage.search || _homeSearching) {
          return;
        }
        _runHomeSearch(includeAllWhenEmpty: true);
      });
    }

    if (_homeSearching) {
      if (_homeSearchResults.isEmpty) {
        return _buildRefreshableStatusBody(
          onRefresh: _handlePullToRefresh,
          child: _buildLoadingBody(
            title: '詳細ブラウズを準備しています',
            message: '登録フォルダとタグ情報を読み込んでいます。',
          ),
        );
      }
    }

    if (_homeSearchErrorMessage != null) {
      return _buildDetailedBrowseResultsBody();
    }

    return _buildDetailedBrowseResultsBody();
  }

  Future<void> _openDetailFromHome(
    MediaItem item, {
    int initialPdfPage = 1,
  }) async {
    final folderRaw = item.folderRaw;

    List<MediaItem> folderItems =
        _folderItemsCache[folderRaw] ??
        (_currentFolderRaw == folderRaw ? _items : const <MediaItem>[]);

    if (folderItems.isEmpty) {
      try {
        folderItems = _filterContentItems(
          await widget.repo.listMedia(FolderHandle(folderRaw)),
        );
        _folderItemsCache[folderRaw] = folderItems;
      } catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('フォルダの読み込みに失敗しました: $error')));
        return;
      }
    }

    var idx = folderItems.indexWhere((entry) => entry.id == item.id);
    if (idx < 0) {
      try {
        folderItems = _filterContentItems(
          await widget.repo.listMedia(FolderHandle(folderRaw)),
        );
        _folderItemsCache[folderRaw] = folderItems;
        idx = folderItems.indexWhere((entry) => entry.id == item.id);
      } catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('フォルダ内容の再取得に失敗しました: $error')));
        return;
      }
    }

    if (idx < 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ファイルが見つかりません。移動または削除された可能性があります。')),
      );
      return;
    }

    if (!mounted) return;

    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ImageDetailPage(
          repo: widget.repo,
          tagService: widget.tagService,
          items: folderItems,
          initialIndex: idx,
          initialPdfPage: initialPdfPage,
        ),
      ),
    );

    if (changed == true) {
      _folderItemsCache.remove(folderRaw);
      _folderItemsCacheRecursive.remove(folderRaw);
      await _refreshVisibleContent();
      return;
    }

    _refreshHomeShowcasesAfterFrame('detail-home-pop');
  }

  Future<void> _refreshAllFavoritesItems() async {
    if (_loadingFavAll) return;
    final remoteItems = await widget.tagService
        .listRemoteFavoriteItems()
        .catchError((_) => null);
    if (remoteItems != null) {
      if (!mounted) return;
      final resolvedFavoriteIds = <String>{};
      for (final item in remoteItems) {
        resolvedFavoriteIds.add(item.id);
        resolvedFavoriteIds.addAll(
          await widget.tagService.favoriteLookupIdsForItem(item),
        );
      }
      if (!mounted) return;
      setState(() {
        _favoriteItemsAll = remoteItems;
        _favoriteResolvedIds = resolvedFavoriteIds;
      });
      return;
    }

    if (_foldersRaw.isEmpty) {
      if (!mounted) return;
      setState(() {
        _favoriteItemsAll = const [];
        _favoriteResolvedIds = <String>{};
      });
      return;
    }

    setState(() => _loadingFavAll = true);

    try {
      for (final raw in _foldersRaw) {
        if (_folderItemsCache.containsKey(raw)) continue;
        final items = _filterContentItems(
          await widget.repo.listMedia(FolderHandle(raw)),
        );
        _folderItemsCache[raw] = items;
      }

      final all = <MediaItem>[];
      final resolvedFavoriteIds = <String>{};
      for (final raw in _foldersRaw) {
        final items = _folderItemsCache[raw] ?? const <MediaItem>[];
        for (final item in items) {
          final lookupIds = await widget.tagService.favoriteLookupIdsForItem(
            item,
          );
          if (lookupIds.any(_favorites.contains)) {
            all.add(item);
            resolvedFavoriteIds.addAll(lookupIds);
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _favoriteItemsAll = all.toList(growable: false);
        _favoriteResolvedIds = resolvedFavoriteIds;
      });
    } finally {
      if (mounted) setState(() => _loadingFavAll = false);
    }
  }
}
