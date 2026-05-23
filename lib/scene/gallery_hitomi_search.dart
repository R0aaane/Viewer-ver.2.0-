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
        _hitomiSearchErrorMessage = null;
      });
      return;
    }
    final loadVersion = ++_hitomiSearchLoadVersion;
    setState(() {
      _hitomiSearching = true;
      _hitomiSearchErrorMessage = null;
    });

    try {
      final results = await _urlImportDownloaderService.searchHitomiGalleries(
        query: query,
        limit: 50,
      );
      if (!mounted || loadVersion != _hitomiSearchLoadVersion) return;
      setState(() {
        _hitomiSearching = false;
        _hitomiSearchResults = results;
      });
    } catch (error, stackTrace) {
      _logUiError('hitomi-search', error, stackTrace);
      if (!mounted || loadVersion != _hitomiSearchLoadVersion) return;
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
    return RawAutocomplete<String>(
      textEditingController: _hitomiSearchCtrl,
      focusNode: _hitomiSearchFocusNode,
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
                  final value = values[index];
                  return ListTile(
                    dense: true,
                    leading: Icon(_hitomiSuggestionIcon(value), size: 20),
                    title: Text(value),
                    onTap: () => _replaceHitomiCurrentToken(value),
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
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      itemCount: _hitomiSearchResults.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        return _buildHitomiResultCard(_hitomiSearchResults[index]);
      },
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
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openHitomiResult(result),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHitomiThumbnail(result),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
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
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    _buildHitomiTagWrap(result),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        TextButton.icon(
                          onPressed: () => _openHitomiResult(result),
                          icon: const Icon(Icons.open_in_new),
                          label: const Text('開く'),
                        ),
                        const SizedBox(width: 6),
                        TextButton.icon(
                          onPressed: _currentFolderRaw == null
                              ? null
                              : () => _importHitomiResult(result),
                          icon: const Icon(Icons.download_outlined),
                          label: const Text('取り込み'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHitomiThumbnail(HitomiSearchResult result) {
    final url = result.thumbnailUrl;
    return SizedBox(
      width: 112,
      height: 156,
      child: _HitomiThumbnailImage(
        urls: result.thumbnailUrls.isEmpty && url != null
            ? <String>[url]
            : result.thumbnailUrls,
      ),
    );
  }

  Widget _buildHitomiTagWrap(HitomiSearchResult result) {
    final tags = <String>[
      ...result.artists.take(2),
      ...result.groups.take(2),
      ...result.series.take(2),
      ...result.characters.take(2),
      ...result.tags.take(8),
    ];
    if (tags.isEmpty) {
      return const SizedBox.shrink();
    }
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final tag in tags)
          Chip(
            visualDensity: VisualDensity.compact,
            label: Text(tag, overflow: TextOverflow.ellipsis),
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
  }

  Iterable<String> _hitomiSuggestionsFor(String raw) {
    final token = _hitomiCurrentToken(raw).toLowerCase();
    if (token.isEmpty) {
      return const <String>[];
    }
    final dynamicValues = <String>{
      for (final result in _hitomiSearchResults) ...[
        for (final value in result.artists) 'artist:${_hitomiTerm(value)}',
        for (final value in result.groups) 'group:${_hitomiTerm(value)}',
        for (final value in result.series) 'series:${_hitomiTerm(value)}',
        for (final value in result.characters)
          'character:${_hitomiTerm(value)}',
        for (final value in result.tags.take(20)) 'tag:${_hitomiTerm(value)}',
      ],
    };
    return <String>[
      ..._hitomiStaticSuggestions,
      ...dynamicValues,
    ].where((value) => value.toLowerCase().startsWith(token)).take(12);
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
