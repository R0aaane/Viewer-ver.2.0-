// ignore_for_file: invalid_use_of_protected_member, file_names
part of 'gridGallery.dart';

extension _GalleryInspector on _GalleryGridPageState {
  Future<void> _inspectLibraryItem(MediaItem item) async {
    if (item.kind == MediaKind.folder) return;
    if (_page == _MainPage.gallery &&
        MediaQuery.sizeOf(context).width >= 1180) {
      setState(() => _libraryInspectedItem = item);
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: 0.9,
        child: _libraryInspector(
          item,
          onClose: () => Navigator.pop(sheetContext),
        ),
      ),
    );
  }

  Widget _libraryInspector(MediaItem item, {required VoidCallback onClose}) {
    return LibraryInspector(
      key: ValueKey(item.id),
      item: item,
      folderLabel: _folderLabelForItem(item),
      preview: item.kind == MediaKind.epub
          ? const _TileShell(icon: Icons.menu_book_outlined)
          : FutureBuilder<ThumbPair>(
              future: _getMediaThumbPair(item),
              builder: (_, snapshot) => snapshot.hasData
                  ? _ThumbImage(bytes: snapshot.data!.front)
                  : _TileShell(loading: !snapshot.hasError),
            ),
      loadTags: () => widget.tagService.listTagsForItem(item.id, item: item),
      onOpen: () => _openDetailFromHome(item),
      onEditTags: () async {
        await _bulkAddTagToItems([item]);
        if (!mounted) return;
        _invalidateGallerySearchCache();
        if (_isGallerySearchActive) await _ensureGallerySearchCacheLoaded();
      },
      onClose: onClose,
    );
  }

  Widget _withLibraryInspector(Widget body) {
    MediaItem? inspected;
    for (final item in _gallerySearchBaseItems()) {
      if (item.id == _libraryInspectedItem?.id) {
        inspected = item;
        break;
      }
    }
    // Keep the center widget at a stable location when the pane opens/closes.
    return Row(
      children: [
        Expanded(child: body),
        if (inspected != null && MediaQuery.sizeOf(context).width >= 1180) ...[
          const VerticalDivider(width: 1),
          SizedBox(
            width: 340,
            child: _libraryInspector(
              inspected,
              onClose: () => setState(() => _libraryInspectedItem = null),
            ),
          ),
        ],
      ],
    );
  }
}
