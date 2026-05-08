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
    final pdfItems = items
        .where((item) => item.kind == MediaKind.pdf)
        .toList(growable: false);
    final coverSections = _buildBookshelfCoverSections(pdfItems);
    final spineSections = _buildBookshelfSpineSections(pdfItems);

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: CustomScrollView(
        physics: _refreshScrollPhysics,
        cacheExtent: 360,
        slivers: [
          if (showPager && _galleryTotal > _GalleryGridPageState._pageSize)
            SliverToBoxAdapter(child: _buildPager()),
          SliverList.builder(
            itemCount: coverSections.length,
            itemBuilder: (context, index) => _BookshelfCoverShelf(
              section: coverSections[index],
              state: this,
              detailItemsSource: items,
            ),
          ),
          SliverList.builder(
            itemCount: spineSections.length,
            itemBuilder: (context, index) => _BookshelfSpineShelf(
              section: spineSections[index],
              state: this,
              isFavorite: (item) => _favorites.contains(item.id),
              isSelected: (item) => _selectedIds.contains(item.id),
              focusedId: _bookshelfFocusItem?.id,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 18)),
        ],
      ),
    );
  }

  List<_BookshelfSection> _buildBookshelfCoverSections(List<MediaItem> items) {
    final visibleIds = items.map((item) => item.id).toSet();
    final sections = <_BookshelfSection>[];
    final used = <String>{};

    void addSection(
      String label,
      Iterable<MediaItem> candidates, {
      int limit = 8,
    }) {
      final picked = <MediaItem>[];
      for (final item in candidates) {
        if (!visibleIds.contains(item.id) || !used.add('$label:${item.id}')) {
          continue;
        }
        picked.add(item);
        if (picked.length >= limit) break;
      }
      if (picked.isNotEmpty) {
        sections.add(_BookshelfSection(label: label, items: picked));
      }
    }

    final focus = _bookshelfFocusItem;
    if (focus != null && visibleIds.contains(focus.id)) {
      addSection('関連作品', _relatedBookshelfItems(focus, items), limit: 10);
    }
    final resume = _homeResumeCard?.item;
    if (resume != null) {
      addSection('続きから読む', [resume], limit: 1);
    }
    addSection('最近閲覧', _homeRecentViewedItems);
    addSection('お気に入り', _homeFavoriteShowcaseItems);
    addSection('最近追加', _homeRecentAddedItems);

    if (sections.isEmpty) {
      addSection('一般', items.take(8));
    }
    return sections;
  }

  Iterable<MediaItem> _relatedBookshelfItems(
    MediaItem base,
    List<MediaItem> items,
  ) sync* {
    final series = _bookshelfTagLabel(base, TagCategory.series);
    final artist = _bookshelfTagLabel(base, TagCategory.artist);
    for (final item in items) {
      if (item.id == base.id) {
        yield item;
        continue;
      }
      final sameSeries =
          series.isNotEmpty &&
          _bookshelfTagLabel(item, TagCategory.series) == series;
      final sameArtist =
          artist.isNotEmpty &&
          _bookshelfTagLabel(item, TagCategory.artist) == artist;
      if (sameSeries || sameArtist) yield item;
    }
  }

  List<_BookshelfSection> _buildBookshelfSpineSections(List<MediaItem> items) {
    final groups = <String, List<MediaItem>>{};
    for (final item in _sortItemsByMode(items, sortMode: _sortMode)) {
      final label = _bookshelfGroupLabel(item);
      groups.putIfAbsent(label, () => <MediaItem>[]).add(item);
    }
    return groups.entries
        .map((entry) => _BookshelfSection(label: entry.key, items: entry.value))
        .toList(growable: false);
  }

  String _bookshelfGroupLabel(MediaItem item) {
    final series = _bookshelfTagLabel(item, TagCategory.series);
    if (series.isNotEmpty) return series;
    final artist = _bookshelfTagLabel(item, TagCategory.artist);
    if (artist.isNotEmpty) return artist;
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

  Future<int> _bookshelfPageCount(MediaItem item) {
    return _bookshelfPageCountCache.putIfAbsent(item.id, () async {
      try {
        return await widget.repo.getPageCount(item);
      } catch (_) {
        return 1;
      }
    });
  }

  void _focusBookshelfItem(MediaItem item) {
    setState(() => _bookshelfFocusItem = item);
  }

  Future<void> _openBookshelfCover(
    MediaItem item,
    List<MediaItem> detailItemsSource,
  ) async {
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

class _BookshelfCoverShelf extends StatelessWidget {
  final _BookshelfSection section;
  final _GalleryGridPageState state;
  final List<MediaItem> detailItemsSource;

  const _BookshelfCoverShelf({
    required this.section,
    required this.state,
    required this.detailItemsSource,
  });

  @override
  Widget build(BuildContext context) {
    return _WoodShelfFrame(
      label: section.label,
      height: 188,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: section.items.length,
        separatorBuilder: (context, index) => const SizedBox(width: 10),
        itemBuilder: (context, index) => _BookCoverTile(
          state: state,
          item: section.items[index],
          detailItemsSource: detailItemsSource,
        ),
      ),
    );
  }
}

class _BookshelfSpineShelf extends StatelessWidget {
  static const int _maxSpines = 36;

  final _BookshelfSection section;
  final _GalleryGridPageState state;
  final bool Function(MediaItem item) isFavorite;
  final bool Function(MediaItem item) isSelected;
  final String? focusedId;

  const _BookshelfSpineShelf({
    required this.section,
    required this.state,
    required this.isFavorite,
    required this.isSelected,
    required this.focusedId,
  });

  @override
  Widget build(BuildContext context) {
    final visible = section.items.take(_maxSpines).toList(growable: false);
    final hiddenCount = section.items.length - visible.length;

    return _WoodShelfFrame(
      label: section.label,
      height: 168,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final item in visible)
            _BookSpineTile(
              state: state,
              item: item,
              favorite: isFavorite(item),
              selected: isSelected(item),
              focused: focusedId == item.id,
            ),
          if (hiddenCount > 0) _MoreBooksTile(count: hiddenCount),
        ],
      ),
    );
  }
}

class _WoodShelfFrame extends StatelessWidget {
  final String label;
  final double height;
  final Widget child;

  const _WoodShelfFrame({
    required this.label,
    required this.height,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF4A1E0F), Color(0xFF7A3217)],
              ),
              borderRadius: BorderRadius.circular(2),
              boxShadow: const [
                BoxShadow(
                  blurRadius: 5,
                  offset: Offset(0, 2),
                  color: Colors.black26,
                ),
              ],
            ),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF8A5124),
                  Color(0xFFC98740),
                  Color(0xFF5B2D13),
                ],
              ),
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
                  SizedBox(height: height, child: child),
                  Container(
                    height: 14,
                    margin: const EdgeInsets.only(top: 6),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xFFE0A151), Color(0xFF693819)],
                      ),
                      borderRadius: BorderRadius.circular(2),
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
  final bool favorite;
  final bool selected;
  final bool focused;

  const _BookSpineTile({
    required this.state,
    required this.item,
    required this.favorite,
    required this.selected,
    required this.focused,
  });

  @override
  Widget build(BuildContext context) {
    final title = state._bookTitle(item);
    final author = state._bookAuthor(item);
    final series = state._bookshelfTagLabel(item, TagCategory.series);
    final color = _stableBookColor(item);

    return Tooltip(
      message: title,
      child: FutureBuilder<int>(
        future: state._bookshelfPageCount(item),
        builder: (context, snapshot) {
          final pages = snapshot.data ?? 60;
          final width = _widthForPages(pages);
          return Padding(
            padding: const EdgeInsets.only(right: 4),
            child: InkWell(
              onTap: () => state._focusBookshelfItem(item),
              onLongPress: () => state._enterSelectMode(item),
              child: SizedBox(
                width: width + 12,
                height: 156,
                child: CustomPaint(
                  painter: _BookSpinePainter(
                    color: color,
                    focused: focused,
                    selected: selected,
                  ),
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(5, 9, 5 + (width * 0.13), 5),
                    child: Stack(
                      children: [
                        if (series.isNotEmpty)
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: Text(
                              series,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 8,
                              ),
                            ),
                          ),
                        Positioned.fill(
                          top: series.isEmpty ? 2 : 16,
                          bottom: 38,
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
                                  fontSize: 12,
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
                            height: 34,
                            alignment: Alignment.center,
                            padding: const EdgeInsets.symmetric(horizontal: 3),
                            color: Colors.black.withValues(alpha: 0.30),
                            child: Text(
                              author,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 8,
                              ),
                            ),
                          ),
                        ),
                        if (favorite)
                          const Positioned(
                            top: 3,
                            right: 2,
                            child: Icon(
                              Icons.star,
                              color: Colors.amber,
                              size: 13,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  double _widthForPages(int pages) {
    final clamped = pages.clamp(1, 500);
    return (22 + clamped / 12).clamp(24, 64).toDouble();
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
      const Color(0xFFE7E2D6),
    ];
    return palette[hash % palette.length];
  }
}

class _BookSpinePainter extends CustomPainter {
  final Color color;
  final bool focused;
  final bool selected;

  const _BookSpinePainter({
    required this.color,
    required this.focused,
    required this.selected,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final depth = (size.width * 0.18).clamp(4.0, 9.0);
    final front = Path()
      ..moveTo(0, depth)
      ..lineTo(size.width - depth, 0)
      ..lineTo(size.width - depth, size.height - depth)
      ..lineTo(0, size.height)
      ..close();
    final side = Path()
      ..moveTo(size.width - depth, 0)
      ..lineTo(size.width, depth)
      ..lineTo(size.width, size.height)
      ..lineTo(size.width - depth, size.height - depth)
      ..close();
    final top = Path()
      ..moveTo(0, depth)
      ..lineTo(depth, 0)
      ..lineTo(size.width - depth, 0)
      ..lineTo(size.width - (depth * 2), depth)
      ..close();

    canvas.drawPath(front, Paint()..color = color);
    canvas.drawPath(
      side,
      Paint()..color = Color.lerp(color, Colors.black, 0.28)!,
    );
    canvas.drawPath(
      top,
      Paint()..color = Color.lerp(color, Colors.white, 0.24)!,
    );
    canvas.drawPath(
      front,
      Paint()
        ..shader = LinearGradient(
          colors: [
            Colors.white.withValues(alpha: 0.22),
            Colors.transparent,
            Colors.black.withValues(alpha: 0.20),
          ],
        ).createShader(Offset.zero & size),
    );

    if (focused || selected) {
      canvas.drawPath(
        front,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = selected ? 3 : 2
          ..color = selected ? Colors.white : Colors.amberAccent,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BookSpinePainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.focused != focused ||
        oldDelegate.selected != selected;
  }
}

class _BookCoverTile extends StatelessWidget {
  final _GalleryGridPageState state;
  final MediaItem item;
  final List<MediaItem> detailItemsSource;

  const _BookCoverTile({
    required this.state,
    required this.item,
    required this.detailItemsSource,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: state._bookTitle(item),
      child: InkWell(
        onTap: () => state._openBookshelfCover(item, detailItemsSource),
        onLongPress: () => state._enterSelectMode(item),
        child: SizedBox(
          width: 118,
          child: Transform(
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.001)
              ..rotateY(-0.055),
            alignment: Alignment.center,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                boxShadow: [
                  BoxShadow(
                    blurRadius: 7,
                    offset: Offset(3, 3),
                    color: Colors.black38,
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
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
      margin: const EdgeInsets.only(left: 4),
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
