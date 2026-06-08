// ignore_for_file: file_names, invalid_use_of_protected_member

part of 'gridGallery.dart';

extension _GallerySearch on _GalleryGridPageState {
  void _handleGallerySearchFocusChange() {
    if (_searchFocusNode.hasFocus) {
      if (!_gallerySearchSuggestionsEnabled && mounted) {
        setState(() => _gallerySearchSuggestionsEnabled = true);
      }
      unawaited(_ensureGallerySearchCacheLoaded());
      return;
    }
    if (!mounted) return;
    if (_gallerySearchSuggestionsEnabled) {
      setState(() => _gallerySearchSuggestionsEnabled = false);
    }
  }

  bool get _isGallerySearchActive => _query.trim().isNotEmpty;

  bool get _isGallerySearchBusy =>
      _gallerySearchLoading || _gallerySearchLoadingTags;

  void _invalidateGallerySearchCache() {
    _gallerySearchLoadVersion++;
    _gallerySearchFolderRaw = null;
    _gallerySearchItemsAll = null;
    _gallerySearchLoading = false;
    _gallerySearchLoadingTags = false;
    _gallerySearchTagsById = <String, List<String>>{};
    _gallerySearchTagDetailsById = <String, List<TagWithId>>{};
  }

  Future<void> _ensureGallerySearchCacheLoaded() async {
    final folder = _folder;
    if (folder == null) return;

    final folderRaw = folder.raw;
    if (_gallerySearchFolderRaw == folderRaw &&
        _gallerySearchItemsAll != null &&
        !_gallerySearchLoading &&
        !_gallerySearchLoadingTags) {
      return;
    }

    if ((_gallerySearchLoading || _gallerySearchLoadingTags) &&
        _gallerySearchFolderRaw == folderRaw) {
      return;
    }

    final loadVersion = ++_gallerySearchLoadVersion;
    if (mounted) {
      setState(() {
        _gallerySearchFolderRaw = folderRaw;
        _gallerySearchLoading = true;
        _gallerySearchLoadingTags = false;
        _gallerySearchItemsAll = null;
        _gallerySearchTagsById = <String, List<String>>{};
        _gallerySearchTagDetailsById = <String, List<TagWithId>>{};
      });
    }

    try {
      final useCurrentPage =
          _galleryTotal > 0 &&
          _galleryTotal <= _items.length &&
          _items.every((item) => item.folderRaw == folderRaw);
      final allItems = useCurrentPage
          ? _items
          : await widget.repo.listMedia(folder);

      if (!mounted ||
          _gallerySearchLoadVersion != loadVersion ||
          _folder?.raw != folderRaw) {
        return;
      }

      widget.tagService.rememberItems(allItems);

      setState(() {
        _gallerySearchItemsAll = allItems.toList(growable: false);
        _gallerySearchLoading = false;
        _gallerySearchLoadingTags = true;
      });

      final nonFolderItems = allItems
          .where((item) => item.kind != MediaKind.folder)
          .toList(growable: false);
      final details = nonFolderItems.isEmpty
          ? const <String, List<TagWithId>>{}
          : await widget.tagService.getDetailedTagsByItems(nonFolderItems);

      if (!mounted ||
          _gallerySearchLoadVersion != loadVersion ||
          _folder?.raw != folderRaw) {
        return;
      }

      setState(() {
        _gallerySearchLoading = false;
        _gallerySearchLoadingTags = false;
        _gallerySearchTagDetailsById = details;
        _gallerySearchTagsById = details.map(
          (key, value) => MapEntry(
            key,
            value.map((entry) => entry.tag.name).toList(growable: false),
          ),
        );
      });
    } catch (error, stackTrace) {
      _logUiError('gallery-search-cache', error, stackTrace);
      if (!mounted ||
          _gallerySearchLoadVersion != loadVersion ||
          _folder?.raw != folderRaw) {
        return;
      }
      setState(() {
        _gallerySearchLoading = false;
        _gallerySearchLoadingTags = false;
      });
    }
  }

  List<MediaItem> _gallerySearchCorpusItems() {
    final folderRaw = _folder?.raw;
    if (folderRaw != null &&
        _gallerySearchFolderRaw == folderRaw &&
        _gallerySearchItemsAll != null) {
      return _gallerySearchItemsAll!;
    }
    return _items;
  }

  List<MediaItem> _gallerySearchBaseItems() {
    if (!_isGallerySearchActive) return _items;
    return _gallerySearchCorpusItems();
  }

  List<String> _searchableTagsFor(MediaItem item) {
    return _gallerySearchTagsById[item.id] ??
        _tagsById[item.id] ??
        const <String>[];
  }

  List<TagWithId> _searchableTagDetailsFor(MediaItem item) {
    return _gallerySearchTagDetailsById[item.id] ??
        _tagDetailsById[item.id] ??
        const <TagWithId>[];
  }

  TagCategory? _tagCategoryForSearchKey(String key) {
    switch (key) {
      case 'artist':
        return TagCategory.artist;
      case 'series':
        return TagCategory.series;
      case 'type':
        return TagCategory.mediaType;
      case 'character':
        return TagCategory.character;
      case 'free':
        return TagCategory.free;
    }
    return null;
  }

  String _tagCategoryLabel(TagCategory category) {
    switch (category) {
      case TagCategory.artist:
        return '作家';
      case TagCategory.series:
        return 'シリーズ';
      case TagCategory.mediaType:
        return '種別';
      case TagCategory.character:
        return 'キャラクター';
      case TagCategory.free:
        return '自由タグ';
    }
  }

  String _mediaKindLabel(MediaKind kind) {
    switch (kind) {
      case MediaKind.folder:
        return 'フォルダ';
      case MediaKind.image:
        return '画像';
      case MediaKind.pdf:
        return 'PDF';
      case MediaKind.epub:
        return 'EPUB';
    }
  }

  IconData _mediaKindIcon(MediaKind kind) {
    switch (kind) {
      case MediaKind.folder:
        return Icons.folder_open_outlined;
      case MediaKind.image:
        return Icons.image_outlined;
      case MediaKind.pdf:
        return Icons.picture_as_pdf_outlined;
      case MediaKind.epub:
        return Icons.menu_book_outlined;
    }
  }

  String _replaceActiveGallerySearchToken(String rawQuery, String replacement) {
    final trimmedRight = rawQuery.trimRight();
    if (trimmedRight.isEmpty) {
      return replacement;
    }

    if (RegExp(r'\s$').hasMatch(rawQuery)) {
      return '$trimmedRight $replacement';
    }

    final tokenMatch = RegExp(r'\S+$').firstMatch(trimmedRight);
    if (tokenMatch == null) {
      return replacement;
    }

    final prefix = trimmedRight.substring(0, tokenMatch.start).trimRight();
    return prefix.isEmpty ? replacement : '$prefix $replacement';
  }

  String? _activeGallerySeriesFilterKey() {
    final tokens = _query
        .trim()
        .split(RegExp(r'\s+'))
        .where((token) => token.isNotEmpty);

    String? active;
    for (final token in tokens) {
      final separator = token.indexOf(':');
      if (separator <= 0 || separator >= token.length - 1) {
        continue;
      }
      final key = token.substring(0, separator).toLowerCase();
      if (key != 'series') {
        continue;
      }
      final value = token.substring(separator + 1).trim();
      if (value.isEmpty) {
        continue;
      }
      active = value.toLowerCase();
    }
    return active;
  }

  List<_FolderSeriesFilterChip> _currentFolderSeriesFilterChips() {
    final folderRaw = _folder?.raw;
    if (folderRaw == null) {
      return const <_FolderSeriesFilterChip>[];
    }

    final useSearchCache =
        _gallerySearchFolderRaw == folderRaw && _gallerySearchItemsAll != null;
    final items = useSearchCache ? _gallerySearchItemsAll! : _items;
    final tagDetailsById = useSearchCache
        ? _gallerySearchTagDetailsById
        : _tagDetailsById;

    final counts = <String, int>{};
    final labels = <String, String>{};

    for (final item in items) {
      if (item.kind != MediaKind.pdf) {
        continue;
      }
      final details = tagDetailsById[item.id] ?? const <TagWithId>[];
      final seenSeriesInItem = <String>{};
      for (final detail in details) {
        if (detail.tag.category != TagCategory.series) {
          continue;
        }
        final name = detail.tag.name.trim();
        if (name.isEmpty) {
          continue;
        }
        final key = name.toLowerCase();
        if (!seenSeriesInItem.add(key)) {
          continue;
        }
        labels.putIfAbsent(key, () => name);
        counts.update(key, (value) => value + 1, ifAbsent: () => 1);
      }
    }

    final chips = counts.entries
        .map(
          (entry) => _FolderSeriesFilterChip(
            name: labels[entry.key] ?? entry.key,
            count: entry.value,
          ),
        )
        .toList(growable: true);
    chips.sort((left, right) {
      final countCompare = right.count.compareTo(left.count);
      if (countCompare != 0) {
        return countCompare;
      }
      return left.name.toLowerCase().compareTo(right.name.toLowerCase());
    });
    return chips.toList(growable: false);
  }

  void _setGallerySearchQuery(
    String value, {
    required bool enableSuggestions,
    bool syncController = false,
  }) {
    if (!mounted) {
      return;
    }

    setState(() {
      _query = value;
      _gallerySearchPageIndex = 0;
      _gallerySearchSuggestionsEnabled =
          enableSuggestions && _searchFocusNode.hasFocus;
    });

    if (syncController && _searchCtrl.text != value) {
      _searchCtrl.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
    }

    if (value.trim().isNotEmpty || _searchFocusNode.hasFocus) {
      unawaited(_ensureGallerySearchCacheLoaded());
    }
  }

  void _toggleGallerySeriesFilter(String seriesName) {
    final trimmed = seriesName.trim();
    if (trimmed.isEmpty) {
      return;
    }

    final normalizedSeries = trimmed.toLowerCase();
    final tokens = _query
        .trim()
        .split(RegExp(r'\s+'))
        .where((token) => token.isNotEmpty)
        .toList(growable: false);

    final nextTokens = <String>[];
    String? currentSeries;
    for (final token in tokens) {
      final separator = token.indexOf(':');
      if (separator > 0 && separator < token.length - 1) {
        final key = token.substring(0, separator).toLowerCase();
        if (key == 'series') {
          currentSeries = token.substring(separator + 1).trim().toLowerCase();
          continue;
        }
      }
      nextTokens.add(token);
    }

    if (currentSeries != normalizedSeries) {
      nextTokens.add('series:$trimmed');
    }

    _setGallerySearchQuery(
      nextTokens.join(' '),
      enableSuggestions: false,
      syncController: true,
    );
  }

  Iterable<_GallerySearchSuggestion> _buildGallerySearchSuggestions(
    TextEditingValue value,
  ) {
    if (!_searchFocusNode.hasFocus || !_gallerySearchSuggestionsEnabled) {
      return const <_GallerySearchSuggestion>[];
    }

    final rawQuery = value.text;
    final trimmedRight = rawQuery.trimRight();
    final hasTrailingSpace =
        rawQuery.isNotEmpty && RegExp(r'\s$').hasMatch(rawQuery);
    final tokenMatch = hasTrailingSpace
        ? null
        : RegExp(r'\S+$').firstMatch(trimmedRight);
    final activeToken = tokenMatch?.group(0) ?? '';
    final normalizedToken = activeToken.toLowerCase();

    final suggestions = <_GallerySearchSuggestion>[];
    final seenQueries = <String>{};

    void addSuggestion(_GallerySearchSuggestion suggestion) {
      final key = suggestion.query.toLowerCase();
      if (seenQueries.add(key)) {
        suggestions.add(suggestion);
      }
    }

    void addOperatorSuggestion(
      String replacement,
      String detail,
      IconData icon,
    ) {
      addSuggestion(
        _GallerySearchSuggestion(
          query: _replaceActiveGallerySearchToken(rawQuery, replacement),
          label: replacement,
          detail: detail,
          icon: icon,
        ),
      );
    }

    final operatorHints = <({String token, String detail, IconData icon})>[
      (token: 'artist:', detail: '作家タグで絞り込み', icon: Icons.person_outline),
      (
        token: 'series:',
        detail: 'シリーズタグで絞り込み',
        icon: Icons.collections_bookmark_outlined,
      ),
      (token: 'type:', detail: '種別タグで絞り込み', icon: Icons.category_outlined),
      (
        token: 'character:',
        detail: 'キャラクタータグで絞り込み',
        icon: Icons.badge_outlined,
      ),
      (token: 'free:', detail: '自由タグで絞り込み', icon: Icons.sell_outlined),
    ];

    if (!normalizedToken.startsWith('#')) {
      for (final hint in operatorHints) {
        final compactHint = hint.token.replaceAll(':', '');
        final compactToken = normalizedToken.replaceAll(':', '');
        if (normalizedToken.isEmpty || compactHint.startsWith(compactToken)) {
          addOperatorSuggestion(hint.token, hint.detail, hint.icon);
        }
      }
    }

    if (normalizedToken.isEmpty ||
        'untagged'.contains(normalizedToken) ||
        '未分類'.contains(normalizedToken)) {
      addOperatorSuggestion(
        'untagged',
        'タグが付いていない項目のみ',
        Icons.label_off_outlined,
      );
    }

    final items = _gallerySearchCorpusItems();
    final uniqueNames = <String>{};
    final uniqueTagNames = <String>{};
    final uniqueCategoryTags = <TagCategory, Set<String>>{};

    for (final item in items) {
      uniqueNames.add(item.displayName);
      for (final tagName in _searchableTagsFor(item)) {
        uniqueTagNames.add(tagName);
      }
      for (final detail in _searchableTagDetailsFor(item)) {
        uniqueCategoryTags
            .putIfAbsent(detail.tag.category, () => <String>{})
            .add(detail.tag.name);
      }
    }

    if (normalizedToken.startsWith('#')) {
      final needle = normalizedToken.substring(1);
      for (final tagName in uniqueTagNames) {
        final normalizedTag = tagName.toLowerCase();
        if (needle.isNotEmpty && !normalizedTag.contains(needle)) continue;
        addSuggestion(
          _GallerySearchSuggestion(
            query: _replaceActiveGallerySearchToken(rawQuery, '#$tagName'),
            label: '#$tagName',
            detail: 'タグ',
            icon: Icons.sell_outlined,
          ),
        );
        if (suggestions.length >= 8) break;
      }
      return suggestions.take(8);
    }

    final separator = normalizedToken.indexOf(':');
    if (separator > 0 && separator < normalizedToken.length) {
      final key = normalizedToken.substring(0, separator);
      final valuePart = normalizedToken.substring(separator + 1);
      final category = _tagCategoryForSearchKey(key);
      if (category != null) {
        final names = uniqueCategoryTags[category] ?? <String>{};
        for (final tagName in names) {
          final normalizedTag = tagName.toLowerCase();
          if (valuePart.isNotEmpty && !normalizedTag.contains(valuePart)) {
            continue;
          }
          addSuggestion(
            _GallerySearchSuggestion(
              query: _replaceActiveGallerySearchToken(
                rawQuery,
                '$key:$tagName',
              ),
              label: '$key:$tagName',
              detail: '${_tagCategoryLabel(category)}タグ',
              icon: Icons.sell_outlined,
            ),
          );
          if (suggestions.length >= 8) break;
        }
        return suggestions.take(8);
      }
    }

    if (normalizedToken.isNotEmpty) {
      for (final name in uniqueNames) {
        if (!name.toLowerCase().contains(normalizedToken)) continue;
        MediaItem? matchedItem;
        for (final item in items) {
          if (item.displayName == name) {
            matchedItem = item;
            break;
          }
        }
        addSuggestion(
          _GallerySearchSuggestion(
            query: _replaceActiveGallerySearchToken(rawQuery, name),
            label: name,
            detail: matchedItem == null
                ? null
                : _mediaKindLabel(matchedItem.kind),
            icon: matchedItem == null
                ? Icons.search
                : _mediaKindIcon(matchedItem.kind),
          ),
        );
        if (suggestions.length >= 8) {
          return suggestions.take(8);
        }
      }

      for (final tagName in uniqueTagNames) {
        if (!tagName.toLowerCase().contains(normalizedToken)) continue;
        addSuggestion(
          _GallerySearchSuggestion(
            query: _replaceActiveGallerySearchToken(rawQuery, '#$tagName'),
            label: '#$tagName',
            detail: 'タグ',
            icon: Icons.sell_outlined,
          ),
        );
        if (suggestions.length >= 8) {
          return suggestions.take(8);
        }
      }
    }

    return suggestions.take(8);
  }

  void _handleGallerySearchChanged(
    String value, {
    bool keepSuggestionsVisible = true,
  }) {
    _setGallerySearchQuery(value, enableSuggestions: keepSuggestionsVisible);
  }

  void _clearGallerySearchQuery() {
    _setGallerySearchQuery(
      '',
      enableSuggestions: _searchFocusNode.hasFocus,
      syncController: true,
    );
  }

  Widget? _buildGallerySearchSuffix() {
    if (!_isGallerySearchBusy && !_isGallerySearchActive) {
      return null;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_isGallerySearchBusy)
          const Padding(
            padding: EdgeInsets.only(right: 4),
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        if (_isGallerySearchActive)
          IconButton(
            tooltip: 'クリア',
            icon: const Icon(Icons.clear),
            onPressed: _clearGallerySearchQuery,
          ),
      ],
    );
  }

  Widget _buildGallerySearchField() {
    return RawAutocomplete<_GallerySearchSuggestion>(
      textEditingController: _searchCtrl,
      focusNode: _searchFocusNode,
      displayStringForOption: (option) => option.query,
      optionsBuilder: _buildGallerySearchSuggestions,
      onSelected: (option) => _handleGallerySearchChanged(
        option.query,
        keepSuggestionsVisible: false,
      ),
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        return TextField(
          controller: controller,
          focusNode: focusNode,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: 'タイトル / #タグ / artist:xxx / series:yyy',
            border: const OutlineInputBorder(),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
            suffixIconConstraints: const BoxConstraints(minWidth: 0),
            suffixIcon: _buildGallerySearchSuffix(),
          ),
          onTap: () {
            if (!_gallerySearchSuggestionsEnabled && mounted) {
              setState(() => _gallerySearchSuggestionsEnabled = true);
            }
            unawaited(_ensureGallerySearchCacheLoaded());
          },
          onTapOutside: (_) => focusNode.unfocus(),
          onChanged: (value) =>
              _handleGallerySearchChanged(value, keepSuggestionsVisible: true),
          onSubmitted: (_) {
            _handleGallerySearchChanged(
              controller.text,
              keepSuggestionsVisible: false,
            );
            onFieldSubmitted();
          },
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        final optionList = options.toList(growable: false);
        if (optionList.isEmpty) {
          return const SizedBox.shrink();
        }

        final maxWidth = _isWideLayout(context)
            ? 520.0
            : MediaQuery.sizeOf(context).width - 24;
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              width: maxWidth,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: ListView.builder(
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  itemCount: optionList.length,
                  itemBuilder: (context, index) {
                    final option = optionList[index];
                    return ListTile(
                      dense: true,
                      leading: Icon(option.icon),
                      title: Text(
                        option.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: option.detail == null
                          ? null
                          : Text(option.detail!),
                      onTap: () => onSelected(option),
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildGallerySeriesFilterRow(List<_FolderSeriesFilterChip> chips) {
    if (chips.isEmpty) {
      return SizedBox(
        height: 36,
        child: Row(
          children: const [
            Text('シリーズ'),
            SizedBox(width: 8),
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        ),
      );
    }

    final activeSeriesKey = _activeGallerySeriesFilterKey();
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          const Text('シリーズ'),
          const SizedBox(width: 8),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: chips.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final chip = chips[index];
                final selected = activeSeriesKey == chip.name.toLowerCase();
                final label = chip.count > 1
                    ? '${chip.name} (${chip.count})'
                    : chip.name;
                return ChoiceChip(
                  label: Text(label),
                  selected: selected,
                  onSelected: (_) => _toggleGallerySeriesFilter(chip.name),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
