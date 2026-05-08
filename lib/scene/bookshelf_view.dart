// ignore_for_file: file_names, invalid_use_of_protected_member

part of 'gridGallery.dart';

class _BookshelfSection {
  final String label;
  final List<MediaItem> items;

  const _BookshelfSection({required this.label, required this.items});
}

extension _BookshelfView on _GalleryGridPageState {
  Widget _buildBookshelf(
    List<MediaItem> items, {
    required bool showFolderLabel,
    required bool showPager,
    required Future<void> Function() onRefresh,
  }) {
    final sections = _buildBookshelfSections(items);
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: CustomScrollView(
        physics: _refreshScrollPhysics,
        cacheExtent: 240,
        slivers: [
          if (showPager && _galleryTotal > _GalleryGridPageState._pageSize)
            SliverToBoxAdapter(child: _buildPager()),
          SliverList.builder(
            itemCount: sections.length,
            itemBuilder: (context, index) => _BookshelfShelf(
              section: sections[index],
              state: this,
              isFavorite: (item) => _favorites.contains(item.id),
              isSelected: (item) => _selectedIds.contains(item.id),
              detailItemsSource: items,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 18)),
        ],
      ),
    );
  }

  List<_BookshelfSection> _buildBookshelfSections(List<MediaItem> items) {
    final groups = <String, List<MediaItem>>{};
    for (final item in items) {
      final label = _bookshelfGroupLabel(item);
      groups.putIfAbsent(label, () => <MediaItem>[]).add(item);
    }
    return groups.entries
        .map((entry) => _BookshelfSection(label: entry.key, items: entry.value))
        .toList(growable: false);
  }

  String _bookshelfGroupLabel(MediaItem item) {
    final details = _searchableTagDetailsFor(item);
    for (final category in const [TagCategory.series, TagCategory.artist]) {
      for (final entry in details) {
        final name = entry.tag.name.trim();
        if (entry.tag.category == category && name.isNotEmpty) return name;
      }
    }
    return '未分類';
  }

  String _bookshelfTagLabel(MediaItem item, TagCategory category) {
    for (final entry in _searchableTagDetailsFor(item)) {
      final name = entry.tag.name.trim();
      if (entry.tag.category == category && name.isNotEmpty) return name;
    }
    return '';
  }

  String _bookTitle(MediaItem item) {
    final name = ItemNameService.formatMediaTitle(
      item.displayName,
      kind: item.kind,
    );
    return name.replaceFirst(RegExp(r'\.pdf$', caseSensitive: false), '');
  }

  String _bookAuthor(MediaItem item) {
    final artist = _bookshelfTagLabel(item, TagCategory.artist);
    if (artist.isNotEmpty) return artist;
    final free = _bookshelfTagLabel(item, TagCategory.free);
    if (free.isNotEmpty) return free;
    return '不明';
  }

  Future<void> _openBookshelfItem(
    MediaItem item,
    List<MediaItem> detailItemsSource,
  ) async {
    if (_selectMode) {
      _toggleSelect(item);
      return;
    }

    if (item.kind == MediaKind.folder) {
      _exitSelectMode();
      await _enterFolder(item);
      return;
    }

    final mediaOnly = detailItemsSource
        .where((entry) => entry.kind != MediaKind.folder)
        .toList(growable: false);
    final index = mediaOnly.indexWhere((entry) => entry.id == item.id);
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ImageDetailPage(
          repo: widget.repo,
          tagService: widget.tagService,
          items: mediaOnly,
          initialIndex: index < 0 ? 0 : index,
          initialPdfPage: 1,
        ),
      ),
    );

    if (changed == true) {
      await _refreshVisibleContent();
      return;
    }
    _refreshHomeShowcasesAfterFrame('detail-bookshelf-pop');
  }
}

class _BookshelfShelf extends StatelessWidget {
  static const int _maxSpines = 10;

  final _BookshelfSection section;
  final _GalleryGridPageState state;
  final bool Function(MediaItem item) isFavorite;
  final bool Function(MediaItem item) isSelected;
  final List<MediaItem> detailItemsSource;

  const _BookshelfShelf({
    required this.section,
    required this.state,
    required this.isFavorite,
    required this.isSelected,
    required this.detailItemsSource,
  });

  @override
  Widget build(BuildContext context) {
    final coverItems = section.items
        .where((item) => item.kind == MediaKind.pdf)
        .take(1)
        .toList(growable: false);
    final coverIds = coverItems.map((item) => item.id).toSet();
    final spineItems = section.items
        .where((item) => !coverIds.contains(item.id))
        .take(_maxSpines)
        .toList(growable: false);
    final hiddenCount =
        section.items.length - coverItems.length - spineItems.length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: Column(
        children: [
          Text(
            section.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [
                  Color(0xFF7A4A22),
                  Color(0xFFB97834),
                  Color(0xFF6A3C18),
                ],
              ),
              borderRadius: BorderRadius.circular(6),
              boxShadow: const [
                BoxShadow(
                  blurRadius: 8,
                  offset: Offset(0, 3),
                  color: Colors.black26,
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 12, 10, 8),
              child: Column(
                children: [
                  SizedBox(
                    height: 174,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final item in coverItems)
                          _BookCoverTile(
                            state: state,
                            item: item,
                            detailItemsSource: detailItemsSource,
                            selected: isSelected(item),
                          ),
                        for (final item in spineItems)
                          _BookSpineTile(
                            state: state,
                            item: item,
                            detailItemsSource: detailItemsSource,
                            favorite: isFavorite(item),
                            selected: isSelected(item),
                          ),
                        if (hiddenCount > 0) _MoreBooksTile(count: hiddenCount),
                      ],
                    ),
                  ),
                  Container(
                    height: 14,
                    margin: const EdgeInsets.only(top: 6),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xFFC98A45), Color(0xFF6E3E19)],
                      ),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BookSpineTile extends StatelessWidget {
  final _GalleryGridPageState state;
  final MediaItem item;
  final List<MediaItem> detailItemsSource;
  final bool favorite;
  final bool selected;

  const _BookSpineTile({
    required this.state,
    required this.item,
    required this.detailItemsSource,
    required this.favorite,
    required this.selected,
  });

  @override
  Widget build(BuildContext context) {
    final color = _stableBookColor(item);
    final title = state._bookTitle(item);
    final author = state._bookAuthor(item);
    final series = state._bookshelfTagLabel(item, TagCategory.series);

    return Tooltip(
      message: title,
      child: Padding(
        padding: const EdgeInsets.only(right: 6),
        child: InkWell(
          onTap: () => state._openBookshelfItem(item, detailItemsSource),
          onLongPress: () => state._enterSelectMode(item),
          borderRadius: BorderRadius.circular(4),
          child: Container(
            width: 54,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(4),
              border: selected
                  ? Border.all(color: Colors.white, width: 3)
                  : null,
              boxShadow: const [
                BoxShadow(
                  blurRadius: 4,
                  offset: Offset(2, 1),
                  color: Colors.black26,
                ),
              ],
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.white.withValues(alpha: 0.18),
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.20),
                        ],
                      ),
                    ),
                  ),
                ),
                if (series.isNotEmpty)
                  Positioned(
                    top: 6,
                    left: 5,
                    right: 5,
                    child: Text(
                      series,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 9),
                    ),
                  ),
                Positioned.fill(
                  top: series.isEmpty ? 8 : 22,
                  bottom: 42,
                  child: Center(
                    child: RotatedBox(
                      quarterTurns: 1,
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    height: 36,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    color: Colors.black.withValues(alpha: 0.32),
                    child: Text(
                      author,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 9),
                    ),
                  ),
                ),
                if (favorite)
                  const Positioned(
                    top: 5,
                    right: 4,
                    child: Icon(Icons.star, color: Colors.amber, size: 14),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color _stableBookColor(MediaItem item) {
    final key = item.id.isNotEmpty ? item.id : item.displayName;
    var hash = 0;
    for (final codeUnit in key.codeUnits) {
      hash = (hash * 31 + codeUnit) & 0x7fffffff;
    }
    final palette = <Color>[
      const Color(0xFF355C7D),
      const Color(0xFF6C5B7B),
      const Color(0xFFC06C84),
      const Color(0xFF2A7F62),
      const Color(0xFF8E5A2A),
      const Color(0xFF8A3B3B),
      const Color(0xFF3E5F8A),
      const Color(0xFF5E6F2F),
    ];
    return palette[hash % palette.length];
  }
}

class _BookCoverTile extends StatelessWidget {
  final _GalleryGridPageState state;
  final MediaItem item;
  final List<MediaItem> detailItemsSource;
  final bool selected;

  const _BookCoverTile({
    required this.state,
    required this.item,
    required this.detailItemsSource,
    required this.selected,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: state._bookTitle(item),
      child: Padding(
        padding: const EdgeInsets.only(right: 10),
        child: InkWell(
          onTap: () => state._openBookshelfItem(item, detailItemsSource),
          onLongPress: () => state._enterSelectMode(item),
          borderRadius: BorderRadius.circular(5),
          child: Container(
            width: 112,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(5),
              border: selected
                  ? Border.all(color: Colors.white, width: 3)
                  : null,
              boxShadow: const [
                BoxShadow(
                  blurRadius: 5,
                  offset: Offset(2, 2),
                  color: Colors.black38,
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: FutureBuilder<ThumbPair>(
              future: state._getMediaThumbPair(item),
              builder: (context, snapshot) {
                if (snapshot.hasData) {
                  return _ThumbImage(bytes: snapshot.data!.front);
                }
                return const _TileShell(loading: true);
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _MoreBooksTile extends StatelessWidget {
  final int count;

  const _MoreBooksTile({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 58,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '+$count',
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
