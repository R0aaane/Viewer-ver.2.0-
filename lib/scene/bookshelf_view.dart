// ignore_for_file: file_names, invalid_use_of_protected_member

part of 'gridGallery.dart';

class _BookshelfSection {
  final String label;
  final List<MediaItem> items;

  const _BookshelfSection({required this.label, required this.items});
}

extension _BookshelfView on _GalleryGridPageState {
  List<Widget> _buildDetailedBrowseBookshelfSlivers(
    List<MediaItem> items, {
    required bool showPager,
  }) {
    final mediaItems = items
        .where((item) => item.kind != MediaKind.folder)
        .toList(growable: false);
    final pdfItems = items
        .where((item) => item.kind == MediaKind.pdf)
        .toList(growable: false);
    final coverSections = _buildBookshelfCoverSections(mediaItems);
    final spineSections = _buildBookshelfSpineSections(pdfItems);

    return [
      if (showPager) SliverToBoxAdapter(child: _buildDetailedBrowsePager()),
      SliverList.builder(
        itemCount: coverSections.length,
        itemBuilder: (context, index) => _BookshelfCoverShelf(
          section: coverSections[index],
          state: this,
          detailItemsSource: mediaItems,
        ),
      ),
      SliverList.builder(
        itemCount: spineSections.length,
        itemBuilder: (context, index) => _BookshelfSpineShelf(
          section: spineSections[index],
          state: this,
          isFavorite: (item) => _favorites.contains(item.id),
          isSelected: (item) => _selectedIds.contains(item.id),
        ),
      ),
      if (showPager) SliverToBoxAdapter(child: _buildDetailedBrowsePager()),
      const SliverToBoxAdapter(child: SizedBox(height: 18)),
    ];
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
      height: 210,
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

  const _BookshelfSpineShelf({
    required this.section,
    required this.state,
    required this.isFavorite,
    required this.isSelected,
  });

  @override
  Widget build(BuildContext context) {
    final visible = section.items.take(_maxSpines).toList(growable: false);
    final hiddenCount = section.items.length - visible.length;

    return _WoodShelfFrame(
      label: section.label,
      height: 182,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final item in visible)
            _BookSpineTile(
              state: state,
              item: item,
              favorite: isFavorite(item),
              selected: isSelected(item),
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
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
      child: Stack(
        alignment: Alignment.topCenter,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 18),
            child: CustomPaint(
              painter: const _WoodBackdropPainter(),
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      const Color(0xFF8B4F22).withValues(alpha: 0.98),
                      const Color(0xFFA9672D).withValues(alpha: 0.96),
                      const Color(0xFF6E3717).withValues(alpha: 0.98),
                    ],
                  ),
                  boxShadow: const [
                    BoxShadow(
                      blurRadius: 12,
                      offset: Offset(0, 4),
                      color: Colors.black38,
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 18, 10, 0),
                  child: Column(
                    children: [
                      SizedBox(
                        height: height,
                        child: Align(
                          alignment: Alignment.bottomLeft,
                          child: child,
                        ),
                      ),
                      const _ShelfBoard(),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 8),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF6B260F), Color(0xFF3B1309)],
              ),
              border: Border.all(color: Color(0xFFB36A2F), width: 0.8),
              boxShadow: const [
                BoxShadow(
                  blurRadius: 7,
                  offset: Offset(0, 3),
                  color: Colors.black45,
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
        ],
      ),
    );
  }
}

class _ShelfBoard extends StatelessWidget {
  const _ShelfBoard();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 22,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFFFC26A), Color(0xFFB66F2F), Color(0xFF6B3516)],
          stops: [0.0, 0.35, 1.0],
        ),
        boxShadow: [
          BoxShadow(
            blurRadius: 3,
            offset: Offset(0, -2),
            color: Colors.black38,
          ),
          BoxShadow(blurRadius: 8, offset: Offset(0, 4), color: Colors.black45),
        ],
      ),
      child: Align(
        alignment: Alignment.topCenter,
        child: Container(height: 3, color: Colors.white24),
      ),
    );
  }
}

class _WoodBackdropPainter extends CustomPainter {
  const _WoodBackdropPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (var i = 0; i < 14; i++) {
      final y = (i + 1) * size.height / 15;
      final alpha = i.isEven ? 0.12 : 0.07;
      linePaint.color = Colors.white.withValues(alpha: alpha);
      final path = Path()..moveTo(0, y);
      path.cubicTo(
        size.width * 0.25,
        y - 12,
        size.width * 0.45,
        y + 10,
        size.width * 0.70,
        y - 4,
      );
      path.cubicTo(
        size.width * 0.86,
        y - 12,
        size.width * 0.94,
        y + 8,
        size.width,
        y,
      );
      canvas.drawPath(path, linePaint);
    }

    final shadePaint = Paint()
      ..shader = LinearGradient(
        colors: [
          Colors.black.withValues(alpha: 0.24),
          Colors.transparent,
          Colors.black.withValues(alpha: 0.18),
        ],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, shadePaint);
  }

  @override
  bool shouldRepaint(covariant _WoodBackdropPainter oldDelegate) => false;
}

class _BookSpineTile extends StatelessWidget {
  final _GalleryGridPageState state;
  final MediaItem item;
  final bool favorite;
  final bool selected;

  const _BookSpineTile({
    required this.state,
    required this.item,
    required this.favorite,
    required this.selected,
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
              onTap: () => state._openDetailFromHome(item),
              onLongPress: () {
                if (!state._selectMode) {
                  state._enterSelectMode(item);
                } else {
                  state._toggleSelect(item);
                }
              },
              child: SizedBox(
                width: width + 12,
                height: 172,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: SizedBox(
                    width: width + 12,
                    height: 158,
                    child: CustomPaint(
                      painter: _BookSpinePainter(
                        color: color,
                        focused: false,
                        selected: selected,
                      ),
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          5,
                          11,
                          5 + (width * 0.13),
                          5,
                        ),
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
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 3,
                                ),
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
    final pageTop = Path()
      ..moveTo(depth * 0.55, depth * 0.42)
      ..lineTo(size.width - (depth * 1.45), depth * 0.34)
      ..lineTo(size.width - (depth * 2.05), depth * 1.28)
      ..lineTo(depth * 0.15, depth * 1.42)
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
      pageTop,
      Paint()..color = Colors.white.withValues(alpha: 0.72),
    );
    final pageLinePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7
      ..color = Colors.black.withValues(alpha: 0.14);
    for (var i = 0; i < 3; i++) {
      final y = depth * (0.62 + i * 0.2);
      canvas.drawLine(
        Offset(depth * 0.7, y),
        Offset(size.width - depth * 1.7, y - 0.4),
        pageLinePaint,
      );
    }
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
    canvas.drawRect(
      Rect.fromLTWH(0, size.height - 7, size.width - depth, 7),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.22)],
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
          width: 124,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              height: 184,
              child: Transform(
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 0.001)
                  ..rotateY(-0.085),
                alignment: Alignment.center,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      top: 5,
                      right: -7,
                      bottom: 2,
                      width: 10,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.34),
                          borderRadius: const BorderRadius.horizontal(
                            right: Radius.circular(2),
                          ),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: const BoxDecoration(
                          boxShadow: [
                            BoxShadow(
                              blurRadius: 9,
                              offset: Offset(4, 5),
                              color: Colors.black45,
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
                  ],
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
