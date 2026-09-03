part of 'gridGallery.dart';

extension _GalleryGridHitomiSearch on _GalleryGridPageState {
  void _ensureHitomiInitialSearchStarted() {
    if (_hitomiInitialSearchStarted || _hitomiSearchCtrl.text.trim().isEmpty) {
      return;
    }
    _hitomiInitialSearchStarted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _page != _MainPage.hitomiSearch || _hitomiSearching) {
        return;
      }
      unawaited(_runHitomiSearch());
    });
  }

  Future<void> _runHitomiSearch() async {
    final query = _hitomiSearchCtrl.text.trim();
    if (query.isEmpty) {
      setState(() {
        _hitomiSearchResults = const <HitomiSearchResult>[];
        _hitomiSearchPageIndex = 0;
        _hitomiSearchTotal = 0;
        _hitomiSearchErrorMessage = null;
      });
      return;
    }
    final loadVersion = ++_hitomiSearchLoadVersion;
    setState(() {
      _hitomiSearching = true;
      _hitomiSearchErrorMessage = null;
      _hitomiSearchPageIndex = 0;
      _hitomiSearchTotal = 0;
      _hitomiImportedGalleryIds = <int>{};
      _hitomiImportedTitleKeys = <String>{};
      _hitomiSelectedGalleryIds = <int>{};
      _hitomiSelectedResultsByGalleryId = <int, HitomiSearchResult>{};
    });

    await _loadHitomiSearchPage(0, loadVersion: loadVersion);
  }

  Future<void> _loadHitomiSearchPage(
    int pageIndex, {
    int? loadVersion,
  }) async {
    final query = _hitomiSearchCtrl.text.trim();
    if (query.isEmpty) return;
    final version = loadVersion ?? ++_hitomiSearchLoadVersion;
    if (loadVersion == null) {
      setState(() {
        _hitomiSearching = true;
        _hitomiSearchErrorMessage = null;
      });
    }
    try {
      final page = await _urlImportDownloaderService.searchHitomiGalleryPage(
        query: query,
        offset: pageIndex * _GalleryGridPageState._hitomiSearchPageSize,
        limit: _GalleryGridPageState._hitomiSearchPageSize,
      );
      if (!mounted || version != _hitomiSearchLoadVersion) return;
      setState(() {
        _hitomiSearching = false;
        _hitomiSearchPageIndex = pageIndex;
        _hitomiSearchResults = page.results;
        _hitomiSearchTotal = page.total;
      });
      unawaited(_refreshHitomiImportedMatches(page.results, version));
    } catch (error, stackTrace) {
      _logUiError('hitomi-search', error, stackTrace);
      if (!mounted || version != _hitomiSearchLoadVersion) return;
      setState(() {
        _hitomiSearching = false;
        _hitomiSearchResults = const <HitomiSearchResult>[];
        _hitomiSearchErrorMessage = '$error';
      });
    }
  }

  Widget _buildHitomiSearchBody() {
    _ensureHitomiInitialSearchStarted();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Expanded(child: _buildHitomiSearchField()),
              const SizedBox(width: 8),
              _buildHitomiOrderingDropdown(),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _hitomiSearching ? null : _runHitomiSearch,
                icon: const Icon(Icons.search),
                label: const Text('検索'),
              ),
            ],
          ),
        ),
        if (_hitomiSearching) const LinearProgressIndicator(),
        if (_hitomiSelectedGalleryIds.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _currentFolderRaw == null
                    ? null
                    : _importSelectedHitomiResults,
                icon: const Icon(Icons.download_outlined),
                label: Text('${_hitomiSelectedGalleryIds.length}件を一括取り込み'),
              ),
            ),
          ),
        Expanded(child: _buildHitomiSearchResults()),
      ],
    );
  }

  Widget _buildHitomiOrderingDropdown() {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _hitomiSearchCtrl,
      builder: (context, value, child) {
        return DropdownButton<String>(
          value: _selectedHitomiOrderingQuery(),
          items: const <DropdownMenuItem<String>>[
            DropdownMenuItem<String>(
              value: 'orderby:date orderbykey:added',
              child: Text('Date Added'),
            ),
            DropdownMenuItem<String>(
              value: 'orderby:datepublished',
              child: Text('Date Published'),
            ),
            DropdownMenuItem<String>(
              value: 'orderby:popular orderbykey:today',
              child: Text('Popular: Today'),
            ),
            DropdownMenuItem<String>(
              value: 'orderby:popular orderbykey:week',
              child: Text('Popular: Week'),
            ),
            DropdownMenuItem<String>(
              value: 'orderby:popular orderbykey:month',
              child: Text('Popular: Month'),
            ),
            DropdownMenuItem<String>(
              value: 'orderby:popular orderbykey:year',
              child: Text('Popular: Year'),
            ),
            DropdownMenuItem<String>(
              value: 'orderby:random',
              child: Text('Random'),
            ),
          ],
          onChanged: (query) {
            if (query == null) return;
            _setHitomiOrderingQuery(query);
          },
        );
      },
    );
  }

  Widget _buildHitomiSearchField() {
    return RawAutocomplete<_HitomiSearchOption>(
      textEditingController: _hitomiSearchCtrl,
      focusNode: _hitomiSearchFocusNode,
      displayStringForOption: (option) => option.query,
      optionsBuilder: (value) => _hitomiSuggestionsFor(value.text),
      onSelected: (_) {},
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        return TextField(
          controller: controller,
          focusNode: focusNode,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            labelText: 'Hitomi 検索',
            hintText: 'group:yoppu language:japanese',
            border: OutlineInputBorder(),
          ),
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _runHitomiSearch(),
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
              constraints: const BoxConstraints(maxWidth: 520, maxHeight: 280),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: values.length,
                itemBuilder: (context, index) {
                  final option = values[index];
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      _hitomiSuggestionIcon(option.query),
                      size: 20,
                    ),
                    title: Text(option.label),
                    subtitle: option.namespace == null
                        ? null
                        : Text('(${option.namespace})'),
                    trailing: option.count == null
                        ? null
                        : Text('${option.count}'),
                    onTap: () => _replaceHitomiCurrentToken(option.query),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHitomiSearchResults() {
    if (_hitomiSearchErrorMessage != null) {
      return _buildHitomiSearchMessage(
        icon: Icons.error_outline,
        message: _hitomiSearchErrorMessage!,
      );
    }
    if (_hitomiSearchResults.isEmpty) {
      return const _HitomiSearchEmptyState();
    }
    final totalPages = _hitomiSearchTotalPages(_hitomiSearchTotal);
    final clamped = _hitomiSearchPageIndex.clamp(0, totalPages - 1).toInt();
    final start = clamped * _GalleryGridPageState._hitomiSearchPageSize;
    final end = start + _hitomiSearchResults.length;
    return CustomScrollView(
      // Avoid preparing off-screen network thumbnails while the user scrolls.
      cacheExtent: 0,
      slivers: [
        if (totalPages > 1)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
            sliver: SliverToBoxAdapter(
              child: _buildHitomiSearchPager(
                currentPage: clamped,
                totalPages: totalPages,
                start: start + 1,
                end: end,
                total: _hitomiSearchTotal,
              ),
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Column(
                  children: [
                    _buildHitomiResultCard(_hitomiSearchResults[index]),
                    const Divider(),
                  ],
                ),
              ),
              childCount: _hitomiSearchResults.length,
            ),
          ),
        ),
        if (totalPages > 1)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            sliver: SliverToBoxAdapter(
              child: _buildHitomiSearchPager(
                currentPage: clamped,
                totalPages: totalPages,
                start: start + 1,
                end: end,
                total: _hitomiSearchTotal,
              ),
            ),
          ),
      ],
    );
  }

  int _hitomiSearchTotalPages(int total) {
    if (total <= 0) return 1;
    return (total + _GalleryGridPageState._hitomiSearchPageSize - 1) ~/
        _GalleryGridPageState._hitomiSearchPageSize;
  }

  Widget _buildHitomiSearchPager({
    required int currentPage,
    required int totalPages,
    required int start,
    required int end,
    required int total,
  }) {
    final pageItems = _hitomiSearchPagerItems(currentPage, totalPages);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text('$start-$end / $total'),
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 6,
          runSpacing: 6,
          children: [
            _buildHitomiPagerCircle(
              icon: Icons.chevron_left,
              tooltip: '前のページ',
              onTap: currentPage <= 0
                  ? null
                  : () => _loadHitomiSearchPage(currentPage - 1),
            ),
            for (final page in pageItems)
              page == null
                  ? const SizedBox(
                      width: 36,
                      child: Center(child: Text('…')),
                    )
                  : _buildHitomiPagerCircle(
                      label: '${page + 1}',
                      selected: page == currentPage,
                      tooltip: '${page + 1} ページ',
                      onTap: page == currentPage
                          ? null
                          : () => _loadHitomiSearchPage(page),
                    ),
            _buildHitomiPagerCircle(
              icon: Icons.chevron_right,
              tooltip: '次のページ',
              onTap: currentPage >= totalPages - 1
                  ? null
                  : () => _loadHitomiSearchPage(currentPage + 1),
            ),
          ],
        ),
      ],
    );
  }

  List<int?> _hitomiSearchPagerItems(int currentPage, int totalPages) {
    if (totalPages <= 7) {
      return List<int?>.generate(totalPages, (index) => index);
    }
    final pages = <int>{
      0,
      1,
      currentPage - 1,
      currentPage,
      currentPage + 1,
      totalPages - 2,
      totalPages - 1,
    }.where((page) => page >= 0 && page < totalPages).toList()
      ..sort();
    final items = <int?>[];
    for (final page in pages) {
      if (items.isNotEmpty) {
        final previous = items.last!;
        if (page - previous > 1) items.add(null);
      }
      items.add(page);
    }
    return items;
  }

  Widget _buildHitomiPagerCircle({
    String? label,
    IconData? icon,
    required String tooltip,
    required VoidCallback? onTap,
    bool selected = false,
  }) {
    final theme = Theme.of(context);
    final background = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.surfaceContainerHighest;
    final foreground = selected
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurface;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: background,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 38,
            height: 38,
            child: Center(
              child: icon == null
                  ? Text(
                      label!,
                      style: TextStyle(
                        color: onTap == null && !selected
                            ? foreground.withValues(alpha: 0.38)
                            : foreground,
                        fontWeight: FontWeight.w700,
                      ),
                    )
                  : Icon(
                      icon,
                      color: onTap == null
                          ? foreground.withValues(alpha: 0.38)
                          : foreground,
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHitomiSearchMessage({
    required IconData icon,
    required String message,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  Widget _buildHitomiResultCard(HitomiSearchResult result) {
    final theme = Theme.of(context);
    final imported = _isHitomiResultImported(result);
    final selected = _hitomiSelectedGalleryIds.contains(result.galleryId);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _openHitomiResult(result),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 560;
            final thumbnail = SizedBox(
              width: compact ? 104 : 92,
              height: compact ? 148 : 132,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _buildHitomiThumbnail(result),
                  if (imported)
                    const Positioned(
                      top: 8,
                      left: 8,
                      child: Chip(
                        visualDensity: VisualDensity.compact,
                        avatar: Icon(Icons.check_circle, size: 18),
                        label: Text('取り込み済み'),
                      ),
                    ),
                ],
              ),
            );
            final details = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  result.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _hitomiResultSubtitle(result),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.white70,
                  ),
                ),
                const SizedBox(height: 8),
                _buildHitomiResultTags(result),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    IconButton(
                      tooltip: selected ? '選択解除' : '選択',
                      onPressed: imported ? null : () => _toggleHitomiResultSelection(result),
                      icon: Icon(selected ? Icons.check_circle : Icons.check_circle_outline),
                    ),
                    IconButton(
                      tooltip: '開く',
                      onPressed: () => _openHitomiResult(result),
                      icon: const Icon(Icons.open_in_new),
                    ),
                    FilledButton.icon(
                      onPressed: _currentFolderRaw == null || imported
                          ? null
                          : () => _importHitomiResult(result),
                      icon: const Icon(Icons.download_outlined, size: 18),
                      label: Text(imported ? '取り込み済み' : '取り込み'),
                    ),
                  ],
                ),
              ],
            );
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: compact
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        thumbnail,
                        const SizedBox(height: 10),
                        details,
                      ],
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        thumbnail,
                        const SizedBox(width: 12),
                        Expanded(child: details),
                      ],
                    ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildHitomiThumbnail(HitomiSearchResult result) {
    final url = result.thumbnailUrl;
    final previewUrlSets = result.previewUrlSets.isEmpty
        ? <List<String>>[
            result.thumbnailUrls.isEmpty && url != null
                ? <String>[url]
                : result.thumbnailUrls,
          ]
        : result.previewUrlSets;
    return _HitomiHoverPreview(urlSets: previewUrlSets);
  }

  Widget _buildHitomiResultTags(HitomiSearchResult result) {
    final tags = <({String label, String query})>[
      for (final value in result.artists.take(2))
        (label: value, query: 'artist:${_hitomiTerm(value)}'),
      for (final value in result.groups.take(2))
        (label: value, query: 'group:${_hitomiTerm(value)}'),
      for (final value in result.series.take(2))
        (label: value, query: 'series:${_hitomiTerm(value)}'),
      for (final value in result.tags)
        (label: value, query: 'tag:${_hitomiTerm(value)}'),
    ];
    if (tags.isEmpty) {
      return const Text('タグ情報はありません');
    }
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final tag in tags.take(4))
          ActionChip(
            visualDensity: VisualDensity.compact,
            label: Text(tag.label, overflow: TextOverflow.ellipsis),
            onPressed: () => _appendHitomiSearchTerm(tag.query),
          ),
        if (tags.length > 4)
          Chip(
            visualDensity: VisualDensity.compact,
            label: Text('+${tags.length - 4}'),
          ),
      ],
    );
  }

  String _hitomiResultSubtitle(HitomiSearchResult result) {
    final parts = <String>[
      '#${result.galleryId}',
      if (result.type?.isNotEmpty == true) result.type!,
      if (result.language?.isNotEmpty == true) result.language!,
      if (result.date?.isNotEmpty == true) result.date!,
    ];
    return parts.join(' / ');
  }

  Future<void> _openHitomiResult(HitomiSearchResult result) async {
    final uri = Uri.tryParse(result.galleryUrl);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _importHitomiResult(HitomiSearchResult result) async {
    final folderRaw = _currentFolderRaw;
    if (folderRaw == null) return;
    await _runUrlImport(
      folder: FolderHandle(folderRaw),
      dialogTitle: 'Hitomi を取り込み',
      dialogDescription: '選択した Hitomi ギャラリーを現在のフォルダへ取り込みます。',
      progressTitle: 'Hitomi を取り込み中',
      successLabel: '取り込み',
      initialSourceText: result.galleryUrl,
    );
    unawaited(
      _refreshHitomiImportedMatches(
        _hitomiSearchResults,
        _hitomiSearchLoadVersion,
      ),
    );
  }

  void _toggleHitomiResultSelection(HitomiSearchResult result) {
    setState(() {
      if (!_hitomiSelectedGalleryIds.add(result.galleryId)) {
        _hitomiSelectedGalleryIds.remove(result.galleryId);
        _hitomiSelectedResultsByGalleryId.remove(result.galleryId);
      } else {
        _hitomiSelectedResultsByGalleryId[result.galleryId] = result;
      }
    });
  }

  Future<void> _importSelectedHitomiResults() async {
    final folderRaw = _currentFolderRaw;
    if (folderRaw == null) return;
    final selected = _hitomiSelectedResultsByGalleryId.values.toList(
      growable: false,
    );
    if (selected.isEmpty) return;

    await _runUrlImport(
      folder: FolderHandle(folderRaw),
      dialogTitle: 'Hitomi を一括取り込み',
      dialogDescription: '選択した ${selected.length} 件の Hitomi ギャラリーを現在のフォルダへ取り込みます。',
      progressTitle: 'Hitomi を一括取り込み中',
      successLabel: '一括取り込み',
      initialSourceText: selected.map((result) => result.galleryUrl).join('\n'),
    );
    if (!mounted) return;
    setState(() {
      _hitomiSelectedGalleryIds = <int>{};
      _hitomiSelectedResultsByGalleryId = <int, HitomiSearchResult>{};
    });
    unawaited(
      _refreshHitomiImportedMatches(
        _hitomiSearchResults,
        _hitomiSearchLoadVersion,
      ),
    );
  }

  Future<void> _refreshHitomiImportedMatches(
    List<HitomiSearchResult> results,
    int loadVersion,
  ) async {
    if (results.isEmpty) {
      if (!mounted || loadVersion != _hitomiSearchLoadVersion) return;
      setState(() {
        _hitomiImportedGalleryIds = <int>{};
        _hitomiImportedTitleKeys = <String>{};
      });
      return;
    }

    List<MediaItem> items;
    try {
      final libraryFolder = await widget.repo.getAppLibraryFolder();
      items = await widget.repo.listMediaRecursiveFiles(libraryFolder);
    } catch (_) {
      items = const <MediaItem>[];
    }
    if (!mounted || loadVersion != _hitomiSearchLoadVersion) return;

    final ids = <int>{};
    final titleKeys = <String>{};
    for (final result in results) {
      final titleKey = _hitomiImportedTitleKey(result.title);
      for (final item in items) {
        if (item.kind == MediaKind.folder) continue;
        if (_hitomiItemMatchesResult(item, result, titleKey: titleKey)) {
          ids.add(result.galleryId);
          if (titleKey.isNotEmpty) {
            titleKeys.add(titleKey);
          }
          break;
        }
      }
    }

    setState(() {
      _hitomiImportedGalleryIds = ids;
      _hitomiImportedTitleKeys = titleKeys;
    });
  }

  bool _hitomiItemMatchesResult(
    MediaItem item,
    HitomiSearchResult result, {
    required String titleKey,
  }) {
    if (_containsHitomiGalleryId(item.displayName, result.galleryId) ||
        _containsHitomiGalleryId(item.id, result.galleryId)) {
      return true;
    }
    if (titleKey.isEmpty) {
      return false;
    }
    return _hitomiImportedTitleKey(item.displayName) == titleKey;
  }

  bool _containsHitomiGalleryId(String value, int galleryId) {
    return RegExp(
      '(^|[^0-9])${RegExp.escape('$galleryId')}([^0-9]|\$)',
    ).hasMatch(value);
  }

  bool _isHitomiResultImported(HitomiSearchResult result) {
    return _hitomiImportedGalleryIds.contains(result.galleryId) ||
        _hitomiImportedTitleKeys.contains(
          _hitomiImportedTitleKey(result.title),
        );
  }

  String _hitomiImportedTitleKey(String value) {
    return p
        .basenameWithoutExtension(value)
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[\s_\-]+'), ' ');
  }

  Iterable<_HitomiSearchOption> _hitomiSuggestionsFor(String raw) {
    final token = _hitomiCurrentToken(raw).toLowerCase();
    if (token.isEmpty) {
      return const <_HitomiSearchOption>[];
    }
    final dynamicCounts = <String, int>{};
    void addDynamic(String value) {
      dynamicCounts[value] = (dynamicCounts[value] ?? 0) + 1;
    }

    for (final result in _hitomiSearchResults) {
      for (final value in result.artists) {
        addDynamic('artist:${_hitomiTerm(value)}');
      }
      for (final value in result.groups) {
        addDynamic('group:${_hitomiTerm(value)}');
      }
      for (final value in result.series) {
        addDynamic('series:${_hitomiTerm(value)}');
      }
      for (final value in result.characters) {
        addDynamic('character:${_hitomiTerm(value)}');
      }
      for (final value in result.tags) {
        addDynamic('tag:${_hitomiTerm(value)}');
      }
    }

    final dynamicValues =
        dynamicCounts.keys
            .where((value) => _hitomiSuggestionMatches(value, token))
            .toList(growable: false)
          ..sort((a, b) {
            final count = (dynamicCounts[b] ?? 0).compareTo(
              dynamicCounts[a] ?? 0,
            );
            if (count != 0) return count;
            return a.compareTo(b);
          });

    final options = <String, _HitomiSearchOption>{};
    for (final value in _hitomiStaticSuggestions.where(
      (value) => value.toLowerCase().startsWith(token),
    )) {
      options[value] = _HitomiSearchOption.staticValue(value);
    }
    for (final suggestion in _hitomiRemoteSuggestions) {
      if (!_hitomiSuggestionMatches(suggestion.query, token)) {
        continue;
      }
      options[suggestion.query] = _HitomiSearchOption(
        query: suggestion.query,
        label: suggestion.value,
        namespace: suggestion.namespace,
        count: suggestion.count,
      );
    }
    for (final value in dynamicValues) {
      options.putIfAbsent(value, () => _HitomiSearchOption.staticValue(value));
    }
    return options.values.take(20);
  }

  void _handleHitomiSearchTextChanged() {
    final token = _hitomiCurrentToken(_hitomiSearchCtrl.text).toLowerCase();
    if (token.isEmpty || token.endsWith(':') || _isHitomiOrderingTerm(token)) {
      _hitomiSuggestionDebounce?.cancel();
      if (_hitomiRemoteSuggestions.isNotEmpty) {
        _setHitomiRemoteSuggestions(const <HitomiSearchSuggestion>[]);
      }
      return;
    }
    final cacheKey = token.replaceAll('_', ' ');
    final cached = _hitomiSuggestionCache[cacheKey];
    if (cached != null) {
      if (_hitomiRemoteSuggestions != cached) {
        _setHitomiRemoteSuggestions(cached);
      }
      return;
    }
    _hitomiSuggestionDebounce?.cancel();
    final loadVersion = ++_hitomiSuggestionLoadVersion;
    _hitomiSuggestionDebounce = Timer(const Duration(milliseconds: 180), () {
      unawaited(_loadHitomiRemoteSuggestions(cacheKey, token, loadVersion));
    });
  }

  Future<void> _loadHitomiRemoteSuggestions(
    String cacheKey,
    String token,
    int loadVersion,
  ) async {
    final suggestions = await _urlImportDownloaderService
        .searchHitomiSuggestions(token);
    _hitomiSuggestionCache[cacheKey] = suggestions;
    if (!mounted || loadVersion != _hitomiSuggestionLoadVersion) {
      return;
    }
    _setHitomiRemoteSuggestions(suggestions);
  }

  bool _hitomiSuggestionMatches(String value, String token) {
    final lower = value.toLowerCase();
    if (lower.startsWith(token)) return true;
    final separatorIndex = token.indexOf(':');
    if (separatorIndex <= 0) {
      return lower.contains(token);
    }
    final namespace = token.substring(0, separatorIndex);
    final query = token.substring(separatorIndex + 1);
    if (query.isEmpty || !lower.startsWith('$namespace:')) {
      return false;
    }
    return lower.substring(namespace.length + 1).contains(query);
  }

  String _hitomiCurrentToken(String raw) {
    final selection = _hitomiSearchCtrl.selection;
    final cursor = selection.isValid ? selection.baseOffset : raw.length;
    final safeCursor = cursor.clamp(0, raw.length).toInt();
    final prefix = raw.substring(0, safeCursor);
    final start = prefix.lastIndexOf(RegExp(r'\s'));
    return raw.substring(start < 0 ? 0 : start + 1, safeCursor);
  }

  void _replaceHitomiCurrentToken(String option) {
    final text = _hitomiSearchCtrl.text;
    final selection = _hitomiSearchCtrl.selection;
    final cursor = selection.isValid ? selection.baseOffset : text.length;
    final safeCursor = cursor.clamp(0, text.length).toInt();
    final beforeCursor = text.substring(0, safeCursor);
    final start = beforeCursor.lastIndexOf(RegExp(r'\s'));
    final tokenStart = start < 0 ? 0 : start + 1;
    var end = safeCursor;
    while (end < text.length && !RegExp(r'\s').hasMatch(text[end])) {
      end += 1;
    }
    final nextText =
        '${text.substring(0, tokenStart)}$option ${text.substring(end)}';
    final nextCursor = tokenStart + option.length + 1;
    _hitomiSearchCtrl.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextCursor),
    );
  }

  void _appendHitomiSearchTerm(String term) {
    final text = _hitomiSearchCtrl.text.trim();
    final terms = text.isEmpty
        ? <String>[]
        : text.split(RegExp(r'\s+')).where((value) => value.isNotEmpty);
    if (terms.contains(term)) {
      return;
    }
    final nextText = <String>[...terms, term].join(' ');
    _hitomiSearchCtrl.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextText.length),
    );
  }

  String _selectedHitomiOrderingQuery() {
    final lower = _hitomiSearchCtrl.text.toLowerCase();
    for (final option in _hitomiOrderingOptions) {
      final terms = option.query.split(RegExp(r'\s+'));
      if (terms.every(lower.contains)) {
        return option.query;
      }
    }
    return _hitomiOrderingOptions.first.query;
  }

  void _setHitomiOrderingQuery(String orderingQuery) {
    final terms = _hitomiSearchCtrl.text
        .trim()
        .split(RegExp(r'\s+'))
        .where((term) => term.isNotEmpty && !_isHitomiOrderingTerm(term))
        .toList(growable: false);
    final nextText = <String>[orderingQuery, ...terms].join(' ').trim();
    _hitomiSearchCtrl.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextText.length),
    );
  }

  bool _isHitomiOrderingTerm(String term) {
    final key = term.split(':').first.toLowerCase();
    return key == 'sortby' ||
        key == 'orderby' ||
        key == 'sortbykey' ||
        key == 'orderbykey' ||
        key == 'sortkey' ||
        key == 'orderkey' ||
        key == 'sortbydirection' ||
        key == 'orderbydirection';
  }

  IconData _hitomiSuggestionIcon(String value) {
    final name = value.split(':').first;
    return switch (name) {
      'artist' => Icons.person_outline,
      'group' => Icons.groups_outlined,
      'series' => Icons.collections_bookmark_outlined,
      'character' => Icons.badge_outlined,
      'language' => Icons.translate,
      'type' => Icons.category_outlined,
      'sortby' || 'orderby' || 'orderbykey' => Icons.sort,
      _ => Icons.sell_outlined,
    };
  }

  String _hitomiTerm(String value) {
    return value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '_');
  }
}

const List<String> _hitomiStaticSuggestions = <String>[
  'artist:',
  'group:',
  'series:',
  'character:',
  'tag:',
  'female:',
  'male:',
  'language:japanese',
  'language:english',
  'language:chinese',
  'type:manga',
  'type:doujinshi',
  'type:artistcg',
  'sortby:date',
  'sortby:popular',
  'orderbykey:week',
  'orderbykey:month',
  'orderbykey:year',
  'orderbydirection:asc',
  'orderbydirection:desc',
];

const List<_HitomiOrderingOption>
_hitomiOrderingOptions = <_HitomiOrderingOption>[
  _HitomiOrderingOption('Date Added', 'orderby:date orderbykey:added'),
  _HitomiOrderingOption('Date Published', 'orderby:datepublished'),
  _HitomiOrderingOption('Popular: Today', 'orderby:popular orderbykey:today'),
  _HitomiOrderingOption('Popular: Week', 'orderby:popular orderbykey:week'),
  _HitomiOrderingOption('Popular: Month', 'orderby:popular orderbykey:month'),
  _HitomiOrderingOption('Popular: Year', 'orderby:popular orderbykey:year'),
  _HitomiOrderingOption('Random', 'orderby:random'),
];

class _HitomiOrderingOption {
  final String label;
  final String query;

  const _HitomiOrderingOption(this.label, this.query);
}

class _HitomiSearchOption {
  final String query;
  final String label;
  final String? namespace;
  final int? count;

  const _HitomiSearchOption({
    required this.query,
    required this.label,
    this.namespace,
    this.count,
  });

  factory _HitomiSearchOption.staticValue(String value) {
    return _HitomiSearchOption(query: value, label: value);
  }
}

class _HitomiHoverPreview extends StatefulWidget {
  final List<List<String>> urlSets;

  const _HitomiHoverPreview({required this.urlSets});

  @override
  State<_HitomiHoverPreview> createState() => _HitomiHoverPreviewState();
}

class _HitomiHoverPreviewState extends State<_HitomiHoverPreview> {
  bool _showSecondPage = false;

  @override
  void didUpdateWidget(covariant _HitomiHoverPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.urlSets != widget.urlSets) {
      _showSecondPage = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = widget.urlSets
        .where((urls) => urls.isNotEmpty)
        .take(2)
        .toList(growable: false);
    if (pages.isEmpty) {
      return const DecoratedBox(
        decoration: BoxDecoration(color: Colors.black26),
        child: Icon(Icons.image_not_supported_outlined),
      );
    }
    final canPreviewSecondPage = pages.length > 1;
    return MouseRegion(
      cursor: canPreviewSecondPage
          ? SystemMouseCursors.click
          : MouseCursor.defer,
      onEnter: (_) {
        if (canPreviewSecondPage) {
          setState(() => _showSecondPage = true);
        }
      },
      onExit: (_) {
        if (_showSecondPage) {
          setState(() => _showSecondPage = false);
        }
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              fit: StackFit.expand,
              children: [
                AnimatedSlide(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  offset: Offset(_showSecondPage ? -1 : 0, 0),
                  child: OverflowBox(
                    alignment: Alignment.centerLeft,
                    minWidth: constraints.maxWidth *
                        (canPreviewSecondPage ? 2 : 1),
                    maxWidth: constraints.maxWidth *
                        (canPreviewSecondPage ? 2 : 1),
                    child: SizedBox(
                      width: constraints.maxWidth *
                          (canPreviewSecondPage ? 2 : 1),
                      height: constraints.maxHeight,
                      child: Row(
                        children: [
                          Expanded(
                            child: _HitomiThumbnailImage(urls: pages.first),
                          ),
                          if (canPreviewSecondPage)
                            Expanded(
                              child: _HitomiThumbnailImage(urls: pages[1]),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (canPreviewSecondPage)
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.66),
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
                            const Icon(Icons.swipe_left_rounded, size: 14),
                            const SizedBox(width: 4),
                            Text(_showSecondPage ? '2枚目' : '表紙'),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _HitomiThumbnailImage extends StatefulWidget {
  final List<String> urls;

  const _HitomiThumbnailImage({required this.urls});

  @override
  State<_HitomiThumbnailImage> createState() => _HitomiThumbnailImageState();
}

class _HitomiThumbnailImageState extends State<_HitomiThumbnailImage> {
  int _index = 0;

  @override
  void didUpdateWidget(covariant _HitomiThumbnailImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.urls != widget.urls) {
      _index = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = _index < widget.urls.length ? widget.urls[_index] : null;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: url == null
          ? const Icon(Icons.image_not_supported_outlined)
          : Image.network(
              url,
              headers: const <String, String>{
                'Referer': 'https://hitomi.la/',
                'User-Agent': 'Mozilla/5.0',
              },
              fit: BoxFit.cover,
              cacheWidth: 480,
              filterQuality: FilterQuality.low,
              errorBuilder: (_, _, _) {
                if (_index + 1 < widget.urls.length) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) {
                      setState(() => _index += 1);
                    }
                  });
                  return const Center(child: CircularProgressIndicator());
                }
                return const Icon(Icons.image_not_supported_outlined);
              },
            ),
    );
  }
}

class _HitomiSearchEmptyState extends StatelessWidget {
  const _HitomiSearchEmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text('Hitomi の検索条件を入力してください。'),
      ),
    );
  }
}
