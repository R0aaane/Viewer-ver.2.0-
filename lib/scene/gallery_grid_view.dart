// ignore_for_file: file_names, invalid_use_of_protected_member

part of 'gridGallery.dart';

class _ThumbTile extends StatelessWidget {
  final MediaRepository repo;
  final MediaItem item;
  final String? subtitle;
  final bool isFavorite;
  final VoidCallback onToggleFavorite;
  final bool selected;
  final FolderTileMode folderTileMode;
  final bool canRenameItem;
  final VoidCallback? onRenameItem;
  final bool canDeleteItem;
  final VoidCallback? onDeleteItem;

  const _ThumbTile({
    required this.repo,
    required this.item,
    this.subtitle,
    required this.isFavorite,
    required this.onToggleFavorite,
    this.selected = false,
    required this.folderTileMode,
    this.canRenameItem = false,
    this.onRenameItem,
    this.canDeleteItem = false,
    this.onDeleteItem,
  });

  String get _displayTitle {
    return ItemNameService.formatMediaTitle(item.displayName, kind: item.kind);
  }

  @override
  Widget build(BuildContext context) {
    if (item.kind == MediaKind.folder) {
      if (folderTileMode == FolderTileMode.labelOnly) {
        return _buildFolderLabelTile(context);
      }
      return _buildFolderPreviewTile(context);
    }
    return _buildMediaTile(context);
  }

  Widget _buildFolderLabelTile(BuildContext context) {
    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(child: _buildFolderPlaceholder(context)),
          Positioned(
            top: 8,
            right: 8,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if ((canRenameItem && onRenameItem != null) ||
                    (canDeleteItem && onDeleteItem != null)) ...[
                  _buildDeleteMenuButton(),
                  const SizedBox(width: 4),
                ],
                const _FolderBadge(),
              ],
            ),
          ),
          Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: _TitleChip(title: _displayTitle, subtitle: subtitle),
          ),
          if (selected) _buildSelectionOverlay(),
        ],
      ),
    );
  }

  Widget _buildFolderPreviewTile(BuildContext context) {
    final galleryState = context
        .findAncestorStateOfType<_GalleryGridPageState>();
    final thumbsEnabled = galleryState?._thumbsEnabled ?? true;

    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(
            child: !thumbsEnabled
                ? _buildFolderPlaceholder(context)
                : FutureBuilder<Uint8List?>(
                    future: galleryState?._getFolderPreviewBytes(item),
                    builder: (context, snapshot) {
                      final bytes = snapshot.data;
                      if (bytes != null && bytes.isNotEmpty) {
                        return Image.memory(
                          bytes,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          filterQuality: FilterQuality.low,
                        );
                      }
                      return _buildFolderPlaceholder(context);
                    },
                  ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if ((canRenameItem && onRenameItem != null) ||
                    (canDeleteItem && onDeleteItem != null)) ...[
                  _buildDeleteMenuButton(),
                  const SizedBox(width: 4),
                ],
                const _FolderBadge(),
              ],
            ),
          ),
          Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: _TitleChip(title: _displayTitle, subtitle: subtitle),
          ),
          if (selected) _buildSelectionOverlay(),
        ],
      ),
    );
  }

  Widget _buildMediaTile(BuildContext context) {
    final galleryState = context
        .findAncestorStateOfType<_GalleryGridPageState>();
    final thumbsEnabled = galleryState?._thumbsEnabled ?? true;

    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(
            child: item.kind == MediaKind.epub
                ? const _TileShell(icon: Icons.menu_book_outlined)
                : !thumbsEnabled
                ? const _TileShell(loading: true)
                : FutureBuilder<ThumbPair>(
                    future:
                        galleryState?._getMediaThumbPair(item) ??
                        repo.readThumbPair(item, maxWidth: 160),
                    builder: (context, snapshot) {
                      if (snapshot.hasError) {
                        return const _TileShell();
                      }
                      if (!snapshot.hasData) {
                        return const _TileShell(loading: true);
                      }
                      return _ThumbImage(bytes: snapshot.data!.front);
                    },
                  ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (item.kind == MediaKind.pdf || item.kind == MediaKind.epub)
                  _PdfBadge(label: ItemNameService.kindLabel(item)),
                const SizedBox(width: 6),
                _FavButton(isFavorite: isFavorite, onPressed: onToggleFavorite),
                if ((canRenameItem && onRenameItem != null) ||
                    (canDeleteItem && onDeleteItem != null)) ...[
                  const SizedBox(width: 4),
                  _buildDeleteMenuButton(),
                ],
              ],
            ),
          ),
          Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: _TitleChip(title: _displayTitle, subtitle: subtitle),
          ),
          if (selected) _buildSelectionOverlay(),
        ],
      ),
    );
  }

  Widget _buildFolderPlaceholder(BuildContext context) {
    return Container(
      alignment: Alignment.center,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Icon(Icons.folder, size: 56),
    );
  }

  Widget _buildDeleteMenuButton() {
    return PopupMenuButton<_ThumbTileMenuAction>(
      tooltip: 'アイテムメニュー',
      padding: EdgeInsets.zero,
      icon: const Icon(Icons.more_vert, size: 18),
      onSelected: (action) {
        if (action == _ThumbTileMenuAction.renameItem) {
          onRenameItem!.call();
        }
        if (action == _ThumbTileMenuAction.deleteItem) {
          onDeleteItem!.call();
        }
      },
      itemBuilder: (context) => [
        if (canRenameItem && onRenameItem != null)
          const PopupMenuItem(
            value: _ThumbTileMenuAction.renameItem,
            child: ListTile(
              leading: Icon(Icons.edit_outlined),
              title: Text('名前を変更'),
            ),
          ),
        if (canDeleteItem && onDeleteItem != null)
          const PopupMenuItem(
            value: _ThumbTileMenuAction.deleteItem,
            child: ListTile(
              leading: Icon(Icons.delete_outline),
              title: Text('削除'),
            ),
          ),
      ],
    );
  }

  Widget _buildSelectionOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.35),
        alignment: Alignment.topRight,
        padding: const EdgeInsets.all(8),
        child: const Icon(Icons.check_circle, size: 26),
      ),
    );
  }
}

class _FavButton extends StatelessWidget {
  final bool isFavorite;
  final VoidCallback onPressed;

  const _FavButton({required this.isFavorite, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            isFavorite ? Icons.star : Icons.star_border,
            size: 18,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

class _PdfBadge extends StatelessWidget {
  final String label;

  const _PdfBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.picture_as_pdf, size: 16, color: Colors.white),
            const SizedBox(width: 4),
            Text(label, style: const TextStyle(color: Colors.white)),
          ],
        ),
      ),
    );
  }
}

class _FolderBadge extends StatelessWidget {
  const _FolderBadge();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          'FOLDER',
          style: TextStyle(color: Colors.white, fontSize: 12),
        ),
      ),
    );
  }
}

class _TitleChip extends StatelessWidget {
  final String title;
  final String? subtitle;

  const _TitleChip({required this.title, this.subtitle});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: subtitle == null ? 2 : 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ThumbImage extends StatelessWidget {
  final Uint8List bytes;
  const _ThumbImage({required this.bytes});

  @override
  Widget build(BuildContext context) {
    return ColorFiltered(
      colorFilter: Theme.of(context).brightness == Brightness.dark
          ? const ColorFilter.matrix(<double>[
              0.85,
              0,
              0,
              0,
              0,
              0,
              0.85,
              0,
              0,
              0,
              0,
              0,
              0.85,
              0,
              0,
              0,
              0,
              0,
              1,
              0,
            ])
          : const ColorFilter.mode(Colors.transparent, BlendMode.dst),
      child: Image.memory(
        bytes,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        filterQuality: FilterQuality.low,
        errorBuilder: (context, error, stack) {
          return Container(
            alignment: Alignment.center,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.broken_image_outlined),
                const SizedBox(height: 6),
                Text(
                  'decode failed\nlen=${bytes.length}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 11),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

extension _GalleryGridView on _GalleryGridPageState {
  void _exitSelectMode() {
    setState(() {
      _selectMode = false;
      _selectedIds.clear();
    });
  }

  void _toggleSelect(MediaItem item) {
    setState(() {
      if (_selectedIds.contains(item.id)) {
        _selectedIds.remove(item.id);
        if (_selectedIds.isEmpty) _selectMode = false;
      } else {
        _selectedIds.add(item.id);
        _selectMode = true;
      }
    });
  }

  void _enterSelectMode(MediaItem item) {
    setState(() {
      _selectMode = true;
      _selectedIds.add(item.id);
    });
  }

  void _selectAll(List<MediaItem> view) {
    setState(() {
      _selectMode = true;
      _selectedIds
        ..clear()
        ..addAll(view.map((e) => e.id));
    });
  }

  void _clearSelection() {
    setState(() {
      _selectedIds.clear();
      _selectMode = false;
    });
  }

  List<MediaItem> _selectedFrom(List<MediaItem> view) {
    if (_selectedIds.isEmpty) return const [];
    return view
        .where((e) => _selectedIds.contains(e.id))
        .toList(growable: false);
  }

  DateTime _safeDateFromDynamic(dynamic v) {
    if (v == null) return DateTime.fromMillisecondsSinceEpoch(0);
    if (v is DateTime) return v;
    if (v is int) {
      if (v < 2000000000) return DateTime.fromMillisecondsSinceEpoch(v * 1000);
      return DateTime.fromMillisecondsSinceEpoch(v);
    }
    if (v is String) {
      final parsed = DateTime.tryParse(v);
      return parsed ?? DateTime.fromMillisecondsSinceEpoch(0);
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  DateTime _getUpdatedAt(MediaItem item) {
    final modified = item.modified;
    if (modified != null) return modified;
    final o = item as dynamic;
    try {
      return _safeDateFromDynamic(o.updatedAt);
    } catch (_) {}
    try {
      return _safeDateFromDynamic(o.modifiedAt);
    } catch (_) {}
    try {
      return _safeDateFromDynamic(o.lastModified);
    } catch (_) {}
    try {
      return _safeDateFromDynamic(o.mtime);
    } catch (_) {}
    try {
      return _safeDateFromDynamic(o.dateModified);
    } catch (_) {}
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  DateTime _getAddedAt(MediaItem item) {
    final o = item as dynamic;
    try {
      return _safeDateFromDynamic(o.addedAt);
    } catch (_) {}
    try {
      return _safeDateFromDynamic(o.createdAt);
    } catch (_) {}
    try {
      return _safeDateFromDynamic(o.ctime);
    } catch (_) {}
    try {
      return _safeDateFromDynamic(o.dateAdded);
    } catch (_) {}
    final modified = item.modified;
    if (modified != null) return modified;
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  ReadingProgressEntry? _readingProgressForItem(MediaItem item) {
    final direct = _readingProgressByItemId[item.id];
    if (direct != null) return direct;
    for (final variant in _idVariants(item.id)) {
      final progress = _readingProgressByItemId[variant];
      if (progress != null) return progress;
    }
    final lookupKey = _readingProgressLookupKey(
      item.folderRaw,
      item.displayName,
    );
    if (lookupKey.isNotEmpty) {
      return _readingProgressByItemId[lookupKey];
    }
    return null;
  }

  bool _isReadItem(MediaItem item) {
    return item.kind == MediaKind.pdf && _readingProgressForItem(item) != null;
  }

  bool _isBookmarkedReadingItem(MediaItem item) {
    return item.kind == MediaKind.pdf &&
        (_readingProgressForItem(item)?.isBookmarked ?? false);
  }

  int _compareByReadStatus(
    MediaItem a,
    MediaItem b, {
    required bool readFirst,
  }) {
    final aRank = _isReadItem(a) ? (readFirst ? 0 : 1) : (readFirst ? 1 : 0);
    final bRank = _isReadItem(b) ? (readFirst ? 0 : 1) : (readFirst ? 1 : 0);
    if (aRank != bRank) return aRank.compareTo(bRank);
    final updated = _getUpdatedAt(b).compareTo(_getUpdatedAt(a));
    if (updated != 0) return updated;
    return _compareNaturalName(a.displayName, b.displayName);
  }

  int _compareByBookmark(MediaItem a, MediaItem b) {
    final aProgress = _readingProgressForItem(a);
    final bProgress = _readingProgressForItem(b);
    final aRank = aProgress?.isBookmarked == true ? 0 : 1;
    final bRank = bProgress?.isBookmarked == true ? 0 : 1;
    if (aRank != bRank) return aRank.compareTo(bRank);
    final lastRead = (bProgress?.lastReadAt ?? _getUpdatedAt(b)).compareTo(
      aProgress?.lastReadAt ?? _getUpdatedAt(a),
    );
    if (lastRead != 0) return lastRead;
    return _compareNaturalName(a.displayName, b.displayName);
  }

  int _compareNaturalName(String left, String right) {
    final a = left.toLowerCase();
    final b = right.toLowerCase();
    final tokenPattern = RegExp(r'\d+|\D+');
    final aTokens = tokenPattern.allMatches(a).map((m) => m.group(0)!).toList();
    final bTokens = tokenPattern.allMatches(b).map((m) => m.group(0)!).toList();
    final count = aTokens.length < bTokens.length
        ? aTokens.length
        : bTokens.length;

    for (var i = 0; i < count; i++) {
      final aToken = aTokens[i];
      final bToken = bTokens[i];
      final aNumber = int.tryParse(aToken);
      final bNumber = int.tryParse(bToken);

      if (aNumber != null && bNumber != null) {
        final numberCompare = aNumber.compareTo(bNumber);
        if (numberCompare != 0) return numberCompare;
        final lengthCompare = aToken.length.compareTo(bToken.length);
        if (lengthCompare != 0) return lengthCompare;
        continue;
      }

      final textCompare = aToken.compareTo(bToken);
      if (textCompare != 0) return textCompare;
    }

    return aTokens.length.compareTo(bTokens.length);
  }

  List<MediaItem> _sortItemsByMode(
    Iterable<MediaItem> items, {
    required _SortMode sortMode,
  }) {
    final sorted = items.toList(growable: true);
    switch (sortMode) {
      case _SortMode.name:
        sorted.sort(
          (a, b) => _compareNaturalName(a.displayName, b.displayName),
        );
        break;
      case _SortMode.updatedAt:
        sorted.sort((a, b) => _getUpdatedAt(b).compareTo(_getUpdatedAt(a)));
        break;
      case _SortMode.addedAt:
        sorted.sort((a, b) => _getAddedAt(b).compareTo(_getAddedAt(a)));
        break;
      case _SortMode.unreadFirst:
        sorted.sort((a, b) => _compareByReadStatus(a, b, readFirst: false));
        break;
      case _SortMode.readFirst:
        sorted.sort((a, b) => _compareByReadStatus(a, b, readFirst: true));
        break;
      case _SortMode.bookmarkedFirst:
        sorted.sort(_compareByBookmark);
        break;
    }
    return sorted.toList(growable: false);
  }

  bool _sortModeUsesReadingProgress(_SortMode sortMode) {
    return sortMode == _SortMode.unreadFirst ||
        sortMode == _SortMode.readFirst ||
        sortMode == _SortMode.bookmarkedFirst;
  }

  List<MediaItem> _applyFilter(
    List<MediaItem> input, {
    required bool? pdfOnly,
  }) {
    Iterable<MediaItem> out = input;

    if (pdfOnly != null) {
      if (pdfOnly) {
        out = out.where(
          (e) => e.kind == MediaKind.folder || e.kind == MediaKind.pdf,
        );
      } else {
        out = out.where(
          (e) => e.kind == MediaKind.folder || e.kind == MediaKind.image,
        );
      }
    }

    final qRaw = _query.trim().toLowerCase();
    if (qRaw.isNotEmpty) {
      final tokens = qRaw
          .split(RegExp(r'\s+'))
          .where((e) => e.isNotEmpty)
          .toList();

      out = out.where((item) {
        final name = item.displayName.toLowerCase();
        final tags = _searchableTagsFor(
          item,
        ).map((e) => e.toLowerCase()).toList(growable: false);
        final detailedTags = _searchableTagDetailsFor(item);

        bool matchToken(String t) {
          if (t == 'untagged' || t == '未分類') {
            return detailedTags.isEmpty;
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
      });
    }

    final list = out.toList(growable: true);
    switch (_sortMode) {
      case _SortMode.name:
        list.sort((a, b) => _compareNaturalName(a.displayName, b.displayName));
        break;
      case _SortMode.updatedAt:
        list.sort((a, b) => _getUpdatedAt(b).compareTo(_getUpdatedAt(a)));
        break;
      case _SortMode.addedAt:
        list.sort((a, b) => _getAddedAt(b).compareTo(_getAddedAt(a)));
        break;
      case _SortMode.unreadFirst:
        list.sort((a, b) => _compareByReadStatus(a, b, readFirst: false));
        break;
      case _SortMode.readFirst:
        list.sort((a, b) => _compareByReadStatus(a, b, readFirst: true));
        break;
      case _SortMode.bookmarkedFirst:
        list.sort(_compareByBookmark);
        break;
    }

    return list.toList(growable: false);
  }

  List<MediaItem> _applyUntagged(List<MediaItem> input) {
    if (!_currentPageMetadataAvailable) {
      return const <MediaItem>[];
    }
    final base = _applyFilter(input, pdfOnly: null);
    return base
        .where((item) => item.kind != MediaKind.folder)
        .where((item) => _searchableTagDetailsFor(item).isEmpty)
        .toList(growable: false);
  }

  List<MediaItem> _gallerySelectionView(int tabIndex) {
    switch (tabIndex) {
      case 1:
        return _applyUntagged(_gallerySearchBaseItems());
      case 2:
        return _applyFilter(_favoriteItemsAll, pdfOnly: null);
      default:
        return _applyFilter(_gallerySearchBaseItems(), pdfOnly: null);
    }
  }

  List<Widget> _buildSearchAppBarActions() {
    if (_selectMode) {
      return _appendTopBarRescanAction([
        IconButton(
          tooltip: '選択解除',
          onPressed: _exitSelectMode,
          icon: const Icon(Icons.close),
        ),
        IconButton(
          tooltip: '全選択',
          onPressed: () => _selectAll(_homeSearchResults),
          icon: const Icon(Icons.select_all),
        ),
        IconButton(
          tooltip: 'クリア',
          onPressed: _clearSelection,
          icon: const Icon(Icons.clear_all),
        ),
        IconButton(
          tooltip: '選択中に一括タグ付け',
          onPressed: () {
            final targets = _selectedFrom(_homeSearchResults);
            _bulkAddTagToItems(targets);
          },
          icon: const Icon(Icons.label_outline),
        ),
        IconButton(
          tooltip: '選択中を削除',
          onPressed: () {
            final targets = _selectedFrom(_homeSearchResults);
            _deleteItemsFromList(targets);
          },
          icon: const Icon(Icons.delete_outline),
        ),
        IconButton(
          tooltip: '選択中をライブラリに取り込む（重複はスキップ）',
          onPressed: () {
            final targets = _selectedFrom(_homeSearchResults);
            _importSelectedToLibrary(targets);
          },
          icon: const Icon(Icons.archive_outlined),
        ),
      ]);
    }

    return _appendTopBarRescanAction([
      IconButton(
        tooltip: 'ホームへ',
        onPressed: () {
          _exitSelectMode();
          setState(() => _page = _MainPage.home);
        },
        icon: const Icon(Icons.home_outlined),
      ),
      IconButton(
        tooltip: 'ギャラリーへ',
        onPressed: () {
          _exitSelectMode();
          setState(() => _page = _MainPage.gallery);
        },
        icon: const Icon(Icons.photo_library_outlined),
      ),
    ]);
  }

  List<Widget> _buildGalleryAppBarActions(TabController controller) {
    if (!_selectMode) {
      return _appendTopBarRescanAction(<Widget>[_buildGalleryOverflowMenu()]);
    }

    return _appendTopBarRescanAction([
      IconButton(
        tooltip: '選択解除',
        onPressed: _exitSelectMode,
        icon: const Icon(Icons.close),
      ),
      IconButton(
        tooltip: '全選択（現在タブ）',
        onPressed: () {
          final view = _gallerySelectionView(controller.index);
          _selectAll(view);
        },
        icon: const Icon(Icons.select_all),
      ),
      IconButton(
        tooltip: 'クリア',
        onPressed: _clearSelection,
        icon: const Icon(Icons.clear_all),
      ),
      IconButton(
        tooltip: '選択中に一括タグ付け',
        onPressed: () {
          final view = _gallerySelectionView(controller.index);
          final targets = _selectedFrom(view);
          _bulkAddTagToItems(targets);
        },
        icon: const Icon(Icons.label_outline),
      ),
      IconButton(
        tooltip: '選択中を削除',
        onPressed: () {
          final view = _gallerySelectionView(controller.index);
          final targets = _selectedFrom(view);
          _deleteItemsFromList(targets);
        },
        icon: const Icon(Icons.delete_outline),
      ),
      IconButton(
        tooltip: '選択中をライブラリに取り込む（重複はスキップ）',
        onPressed: () {
          final view = _gallerySelectionView(controller.index);
          final targets = _selectedFrom(view);
          _importSelectedToLibrary(targets);
        },
        icon: const Icon(Icons.archive_outlined),
      ),
    ]);
  }

  Widget _buildGalleryMainBody() {
    if (_initializing) {
      return _buildRefreshableStatusBody(
        onRefresh: _handlePullToRefresh,
        child: _buildLoadingBody(
          title: '初期化中です',
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

    if (_folder == null) {
      if (_foldersRaw.isEmpty) {
        return _buildRefreshableStatusBody(
          onRefresh: _handlePullToRefresh,
          child: _buildEmptyBody(
            title: '表示できるフォルダがありません',
            message: 'まずは $_primaryAddActionLabel を実行してください。',
            actionLabel: _primaryAddActionLabel,
            onAction: _addFolder,
          ),
        );
      }
      return _buildRefreshableStatusBody(
        onRefresh: _handlePullToRefresh,
        child: _buildEmptyBody(
          title: 'フォルダが未選択です',
          message: 'サイドバーまたはホーム画面から表示するフォルダを選択してください。',
          actionLabel: 'ホームを開く',
          onAction: () => setState(() => _page = _MainPage.home),
        ),
      );
    }

    if (_galleryLoadErrorMessage != null && !_loading) {
      return _buildRefreshableStatusBody(
        onRefresh: _handlePullToRefresh,
        child: _buildErrorBody(
          title: 'フォルダを読み込めませんでした',
          message: _galleryLoadErrorMessage!,
          onAction: () => _loadFolder(
            _folder!,
            saveAsLast: false,
            pageIndex: _galleryPageIndex,
          ),
        ),
      );
    }

    if (_loading) {
      final progress = _loadTotal > 0 ? _loadProcessed / _loadTotal : null;
      final message = _loadTotal > 0
          ? '$_loadProcessed / $_loadTotal 件を読み込んでいます。'
          : 'フォルダの内容を読み込んでいます。';
      return _buildRefreshableStatusBody(
        onRefresh: _handlePullToRefresh,
        child: _buildLoadingBody(
          title: 'フォルダを読み込んでいます',
          message: message,
          progress: progress,
        ),
      );
    }

    if (_items.isEmpty) {
      return _buildRefreshableStatusBody(
        onRefresh: _handlePullToRefresh,
        child: _buildEmptyBody(
          title: 'このフォルダに画像や PDF がありません',
          message: '別のフォルダを選ぶか、$_galleryAddFileLabel を実行してください。',
          actionLabel: _galleryAddFileLabel,
          onAction: _repoCapabilities.canUpload ? _importToCurrentFolder : null,
        ),
      );
    }

    final galleryItems = _gallerySelectionView(0);
    final untaggedItems = _gallerySelectionView(1);
    final favoriteItems = _gallerySelectionView(2);

    return TabBarView(
      children: [
        _buildGrid(galleryItems, onRefresh: _handlePullToRefresh),
        _currentPageMetadataAvailable
            ? _buildGrid(untaggedItems, onRefresh: _handlePullToRefresh)
            : _buildRefreshableStatusBody(
                onRefresh: _handlePullToRefresh,
                child: _buildEmptyBody(
                  title: 'タグ情報を読み込めませんでした',
                  message: 'タグなし一覧はメタデータが取得できたときだけ表示されます。',
                ),
              ),
        _loadingFavAll
            ? _buildRefreshableStatusBody(
                onRefresh: _handlePullToRefresh,
                child: _buildLoadingBody(
                  title: 'お気に入りを集計しています',
                  message: '登録済みのお気に入りを確認しています。',
                ),
              )
            : _buildGrid(
                favoriteItems,
                showFolderLabel: true,
                showPager: false,
                onRefresh: _handlePullToRefresh,
              ),
      ],
    );
  }

  Future<void> _bulkAddTagToItems(List<MediaItem> targets) async {
    final mediaTargets = targets
        .where((item) => item.kind != MediaKind.folder)
        .toList(growable: false);
    if (mediaTargets.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('対象がありません')));
      return;
    }

    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => TagAssignAfterImportPage(
          items: mediaTargets,
          tagService: widget.tagService,
          title: '一括タグ付与（${mediaTargets.length}件）',
          applyLabel: '${mediaTargets.length}件にタグを付ける',
        ),
      ),
    );

    if (changed != true || !mounted) {
      return;
    }

    try {
      final got = await widget.tagService.getTagNamesByItems(mediaTargets);
      if (!mounted) return;
      setState(() {
        for (final e in got.entries) {
          for (final vv in _idVariants(e.key)) {
            _dbTagsByItemId[vv] = e.value;
          }
        }
      });
      await _refreshCurrentPageTags();
      await _refreshArtistTagCounts();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${mediaTargets.length}件にタグを付与しました')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('タグ反映の更新に失敗しました: $e')));
    }
  }

  Widget _buildGrid(
    List<MediaItem> items, {
    bool showFolderLabel = false,
    bool showPager = true,
    required Future<void> Function() onRefresh,
  }) {
    if (items.isEmpty) {
      return _buildRefreshableStatusBody(
        onRefresh: onRefresh,
        child: _buildEmptyBody(
          title: '該当するアイテムがありません',
          message: '引っ張って更新するか、別の条件を試してください。',
        ),
      );
    }

    final useSearchPager = _isGallerySearchActive && showPager;
    final visibleItems = useSearchPager
        ? _gallerySearchPageItems(items)
        : items;

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: CustomScrollView(
        physics: _refreshScrollPhysics,
        cacheExtent: 200,
        slivers: [
          if (useSearchPager &&
              items.length > _GalleryGridPageState._gallerySearchPageSize)
            SliverToBoxAdapter(child: _buildGallerySearchPager(items.length))
          else if (showPager && _galleryTotal > _GalleryGridPageState._pageSize)
            SliverToBoxAdapter(child: _buildPager()),
          SliverPadding(
            padding: const EdgeInsets.all(12),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.75,
              ),
              delegate: SliverChildBuilderDelegate((context, index) {
                final item = visibleItems[index];
                return _buildGridTile(
                  item,
                  showFolderLabel: showFolderLabel,
                  detailItemsSource: items,
                );
              }, childCount: visibleItems.length),
            ),
          ),
        ],
      ),
    );
  }

  int _gallerySearchTotalPages(int total) {
    if (total <= 0) return 1;
    return (total + _GalleryGridPageState._gallerySearchPageSize - 1) ~/
        _GalleryGridPageState._gallerySearchPageSize;
  }

  List<MediaItem> _gallerySearchPageItems(List<MediaItem> items) {
    if (items.isEmpty) return const <MediaItem>[];
    final totalPages = _gallerySearchTotalPages(items.length);
    final clamped = _gallerySearchPageIndex.clamp(0, totalPages - 1);
    final start = clamped * _GalleryGridPageState._gallerySearchPageSize;
    final end = (start + _GalleryGridPageState._gallerySearchPageSize).clamp(
      0,
      items.length,
    );
    return items.sublist(start, end);
  }

  Widget _buildGallerySearchPager(int total) {
    if (total <= _GalleryGridPageState._gallerySearchPageSize) {
      return const SizedBox.shrink();
    }

    final totalPages = _gallerySearchTotalPages(total);
    final clamped = _gallerySearchPageIndex.clamp(0, totalPages - 1);
    final start = clamped * _GalleryGridPageState._gallerySearchPageSize + 1;
    final end = ((clamped + 1) * _GalleryGridPageState._gallerySearchPageSize)
        .clamp(0, total);
    final useDropdown = totalPages > 10;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Row(
        children: [
          Text('$start-$end / $total'),
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
                setState(() => _gallerySearchPageIndex = value);
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
                          setState(() => _gallerySearchPageIndex = index);
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

  Widget _buildGridTile(
    MediaItem item, {
    required bool showFolderLabel,
    required List<MediaItem> detailItemsSource,
  }) {
    final isFavorite = _favorites.contains(item.id);
    final isSelected = _selectedIds.contains(item.id);

    return ControllerFocusable(
      debugLabel: 'gallery-tile-${item.id}',
      borderRadius: BorderRadius.circular(10),
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

        _refreshHomeShowcasesAfterFrame('detail-gallery-pop');
      },
      child: _ThumbTile(
        repo: widget.repo,
        item: item,
        subtitle: showFolderLabel ? _folderLabelForItem(item) : null,
        isFavorite: isFavorite,
        onToggleFavorite: () => _toggleFavorite(item),
        selected: isSelected,
        folderTileMode: _folderTileMode,
        canRenameItem: !_selectMode && _canRenameItem(item),
        onRenameItem: () => _renameItemFromList(item),
        canDeleteItem: !_selectMode && _canDeleteItem(item),
        onDeleteItem: () => _deleteItemFromList(item),
      ),
    );
  }

  Widget _buildPager() {
    if (_galleryTotal <= _GalleryGridPageState._pageSize) {
      return const SizedBox.shrink();
    }

    final totalPages =
        (_galleryTotal + _GalleryGridPageState._pageSize - 1) ~/
        _GalleryGridPageState._pageSize;
    final clamped = _galleryPageIndex.clamp(0, totalPages - 1);
    final start = clamped * _GalleryGridPageState._pageSize + 1;
    final end = ((clamped + 1) * _GalleryGridPageState._pageSize).clamp(
      0,
      _galleryTotal,
    );
    final useDropdown = totalPages > 10;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Row(
        children: [
          Text('$start-$end / $_galleryTotal'),
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
                if (value == null) return;
                _loadGalleryPage(value);
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
                        onSelected: (_) => _loadGalleryPage(index),
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
}
