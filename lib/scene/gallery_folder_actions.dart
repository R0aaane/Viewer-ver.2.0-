// ignore_for_file: file_names, invalid_use_of_protected_member

part of 'gridGallery.dart';

extension _GalleryFolderActions on _GalleryGridPageState {
  String _parentDirOfFullPath(String fullPath) {
    final p = fullPath.replaceAll('/', '\\');
    final idx = p.lastIndexOf('\\');
    if (idx <= 0) return p;
    return p.substring(0, idx);
  }

  Future<void> _enterFolder(MediaItem folderItem) async {
    if (_folder == null) return;

    _dirStack.add(_FolderNavState(_folder!, _galleryPageIndex));

    await _loadFolder(
      FolderHandle(folderItem.id),
      saveAsLast: false,
      pageIndex: 0,
    );
  }

  Future<void> _goUpFolder() async {
    if (_dirStack.isEmpty) return;
    final prev = _dirStack.removeLast();

    await _loadFolder(
      prev.folder,
      saveAsLast: false,
      pageIndex: prev.pageIndex,
    );
  }

  String _basename(String raw) {
    String s = raw;
    if (s.startsWith('content://')) {
      try {
        final u = Uri.parse(s);
        final segs = u.pathSegments;

        String? encoded;
        final ti = segs.indexOf('tree');
        if (ti >= 0 && ti + 1 < segs.length) {
          encoded = segs[ti + 1];
        } else {
          final di = segs.indexOf('document');
          if (di >= 0 && di + 1 < segs.length) {
            encoded = segs[di + 1];
          }
        }
        if (encoded != null && encoded.isNotEmpty) {
          s = encoded;
        }
      } catch (_) {}
    }

    for (int i = 0; i < 2; i++) {
      if (!s.contains('%')) break;
      try {
        s = Uri.decodeComponent(s);
      } catch (_) {
        break;
      }
    }

    final colon = s.indexOf(':');
    if (colon >= 0) s = s.substring(colon + 1);

    s = s.replaceAll('\\', '/');
    final slash = s.lastIndexOf('/');
    if (slash >= 0) s = s.substring(slash + 1);

    return s.trim().isEmpty ? raw : s.trim();
  }

  String _displayTitleForItem(MediaItem item) {
    return ItemNameService.formatMediaTitle(item.displayName, kind: item.kind);
  }

  String _folderLabel(String raw) {
    final a = _folderAliases[raw];
    final sanitized = a == null
        ? null
        : _sanitizeFolderAlias(a, fallbackRaw: raw);
    if (sanitized != null && sanitized.trim().isNotEmpty) {
      return sanitized.trim();
    }
    return _basename(raw);
  }

  String? _sanitizeFolderAlias(String? alias, {required String fallbackRaw}) {
    if (alias == null) {
      return null;
    }
    final trimmed = alias.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    if (_looksLikeMojibake(trimmed)) {
      final fallback = _basename(fallbackRaw).trim();
      return fallback.isEmpty ? 'フォルダ' : fallback;
    }
    if (trimmed == 'Library') {
      return '保管庫';
    }
    return trimmed;
  }

  bool _looksLikeMojibake(String value) {
    const suspiciousCodePoints = <int>{
      0x7E5D,
      0x7E67,
      0x7E3A,
      0x8373,
      0x8B5B,
      0x900B,
      0x8B80,
      0x9A55,
      0x8711,
      0x96A7,
      0x908F,
      0x9666,
      0x9049,
      0x8389,
      0x8816,
      0x95BE,
      0x9AE2,
    };

    var suspiciousHits = 0;
    var halfwidthHits = 0;
    for (final rune in value.runes) {
      if (rune == 0xFFFD) {
        return true;
      }
      if (rune >= 0xFF61 && rune <= 0xFF9F) {
        halfwidthHits++;
      }
      if (suspiciousCodePoints.contains(rune)) {
        suspiciousHits++;
      }
    }

    return suspiciousHits >= 2 || halfwidthHits >= 2;
  }

  Future<void> _persistFolderAliases() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _PrefsKeys.folderAliasesJson,
      jsonEncode(_folderAliases),
    );
  }

  Future<void> _renameFolder(String raw) async {
    final controller = TextEditingController(
      text: _folderAliases[raw] ?? _basename(raw),
    );
    final result = await showControllerDialog<String>(
      context: context,
      autofocusBoundary: false,
      autofocusFirstFocusable: false,
      requestFocus: false,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('フォルダ名を変更'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '表示名（タイトル）',
              hintText: '例: 漫画 / 雑誌 / 保存用 など',
            ),
            onSubmitted: (_) => Navigator.of(ctx).pop(controller.text),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('キャンセル'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );

    if (result == null) return;

    final name = result.trim();
    setState(() {
      if (name.isEmpty) {
        _folderAliases.remove(raw);
      } else {
        _folderAliases[raw] = name;
      }
    });
    await _persistFolderAliases();
  }

  String _folderLabelForItem(MediaItem item) {
    final folderRaw = item.folderRaw.trim();
    if (folderRaw.isNotEmpty) {
      for (final raw in _foldersRaw) {
        if (_sameFolderLocation(raw, folderRaw)) {
          return _folderLabel(raw);
        }
      }
      if (folderRaw.startsWith('content://') ||
          folderRaw.startsWith('remote://')) {
        return _folderLabel(folderRaw);
      }
    }

    final itemNorm = _normalizePath(item.id);

    String? bestMatchRaw;
    var bestLen = -1;

    for (final raw in _foldersRaw) {
      final folderNorm = _normalizePath(raw);

      final ok = itemNorm == folderNorm || itemNorm.startsWith('$folderNorm\\');
      if (!ok) continue;

      if (folderNorm.length > bestLen) {
        bestLen = folderNorm.length;
        bestMatchRaw = raw;
      }
    }

    if (bestMatchRaw != null) {
      return _folderLabel(bestMatchRaw);
    }

    final parentRaw = folderRaw.isNotEmpty
        ? folderRaw
        : _parentDirOfFullPath(item.id);
    return _basename(parentRaw);
  }

  String _normalizePath(String p) {
    var s = p.replaceAll('/', '\\');
    while (s.endsWith('\\')) {
      s = s.substring(0, s.length - 1);
    }
    return s.toLowerCase();
  }

  bool _sameFolderLocation(String left, String right) {
    final lhs = left.trim();
    final rhs = right.trim();
    if (lhs.isEmpty || rhs.isEmpty) {
      return false;
    }
    if (lhs.startsWith('content://') || rhs.startsWith('content://')) {
      return lhs == rhs;
    }
    return _normalizePath(lhs) == _normalizePath(rhs);
  }

  Future<void> _saveLastFolder(FolderHandle folder) async {
    if (widget.repo.isRemoteMode) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_PrefsKeys.lastFolderRaw, folder.raw);
  }

  Future<void> _loadFolder(
    FolderHandle folder, {
    required bool saveAsLast,
    int pageIndex = 0,
  }) async {
    _invalidateGallerySearchCache();
    setState(() {
      _thumbsEnabled = false;
      _folder = folder;
      _loading = true;
      _items = const [];
      _galleryLoadErrorMessage = null;
      _loadProcessed = 0;
      _loadTotal = 0;
      _galleryPageIndex = pageIndex;
      _galleryTotal = 0;
    });
    _folderPreviewInFlight.clear();

    if (saveAsLast) {
      await _saveLastFolder(folder);
    }

    try {
      final offset = pageIndex * _GalleryGridPageState._pageSize;
      final res = await widget.repo.listMediaPage(
        folder,
        offset: offset,
        limit: _GalleryGridPageState._pageSize,
        onProgress: (p, t) {
          if (!mounted) return;
          setState(() {
            _loadProcessed = p;
            _loadTotal = t;
          });
        },
      );
      if (!mounted) return;

      final maxPageIndex = res.total <= 0
          ? 0
          : (res.total - 1) ~/ _GalleryGridPageState._pageSize;
      if (res.total > 0 && pageIndex > maxPageIndex) {
        await _loadFolder(folder, saveAsLast: false, pageIndex: maxPageIndex);
        return;
      }

      setState(() {
        _galleryTotal = res.total;
        _items = res.items;
        _loading = false;
        _galleryLoadErrorMessage = null;
      });

      widget.tagService.rememberItems(res.items);
      unawaited(_refreshCurrentPageTags(res.items));
      _prepareVisibleMedia(res.items);

      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (!mounted) return;
        setState(() => _thumbsEnabled = true);
      });

      _folderItemsCache[folder.raw] = _items;
      await _refreshAllFavoritesItems();
      unawaited(_refreshHomeShowcases());
      unawaited(_ensureGallerySearchCacheLoaded());
      if (_query.trim().isNotEmpty) {
        _setGallerySearchQuery(
          _query,
          enableSuggestions: _gallerySearchSuggestionsEnabled,
        );
      }
    } catch (e, st) {
      _logUiError('load-folder', e, st);
      final message = 'フォルダの読み込みに失敗しました: $e';
      if (!mounted) return;
      setState(() {
        _loading = false;
        _galleryLoadErrorMessage = message;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _loadGalleryPage(int pageIndex) async {
    final folder = _folder;
    if (folder == null) return;

    final offset = pageIndex * _GalleryGridPageState._pageSize;

    setState(() {
      _thumbsEnabled = false;
      _loading = true;
      _items = const [];
      _galleryLoadErrorMessage = null;
      _loadProcessed = 0;
      _loadTotal = 0;
    });

    try {
      final res = await widget.repo.listMediaPage(
        folder,
        offset: offset,
        limit: _GalleryGridPageState._pageSize,
        onProgress: (p, t) {
          if (!mounted) return;
          setState(() {
            _loadProcessed = p;
            _loadTotal = t;
          });
        },
      );
      if (!mounted) return;

      final maxPageIndex = res.total <= 0
          ? 0
          : (res.total - 1) ~/ _GalleryGridPageState._pageSize;
      if (res.total > 0 && pageIndex > maxPageIndex) {
        await _loadGalleryPage(maxPageIndex);
        return;
      }

      setState(() {
        _galleryPageIndex = pageIndex;
        _galleryTotal = res.total;
        _items = res.items;
        _loading = false;
        _galleryLoadErrorMessage = null;
      });

      widget.tagService.rememberItems(res.items);
      unawaited(_refreshCurrentPageTags(res.items));
      _prepareVisibleMedia(res.items);

      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (!mounted) return;
        setState(() => _thumbsEnabled = true);
      });
      if (_query.trim().isNotEmpty) {
        unawaited(_ensureGallerySearchCacheLoaded());
      }
    } catch (e, st) {
      _logUiError('load-gallery-page', e, st);
      final message = 'ページの読み込みに失敗しました: $e';
      if (!mounted) return;
      setState(() {
        _loading = false;
        _galleryLoadErrorMessage = message;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _persistFolders() async {
    if (widget.repo.isRemoteMode) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_PrefsKeys.folders, _foldersRaw);
    if (_currentFolderRaw == null) {
      await prefs.remove(_PrefsKeys.currentFolder);
    } else {
      await prefs.setString(_PrefsKeys.currentFolder, _currentFolderRaw!);
    }
  }

  Future<void> _addFolder() async {
    if (_repoCapabilities.canImportToHost) {
      await _importToHostWithTags();
      return;
    }
    if (!_repoCapabilities.canAddLocalFolder) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('このモードではフォルダ追加は未対応です')));
      return;
    }

    final folder = await widget.repo.pickFolder();
    if (folder == null) return;
    final raw = folder.raw;
    final next = List<String>.from(_foldersRaw);
    _dirStack.clear();
    if (!next.contains(raw)) {
      next.add(raw);
    }
    setState(() {
      _foldersRaw = next.toList(growable: false);
      _currentFolderRaw = raw;
    });
    await _persistFolders();
    await _loadFolder(folder, saveAsLast: false);
  }

  Future<void> _switchFolder(String raw) async {
    if (_currentFolderRaw == raw) return;
    _dirStack.clear();

    setState(() {
      _currentFolderRaw = raw;
    });

    await _persistFolders();
    await _loadFolder(FolderHandle(raw), saveAsLast: false);
  }

  Future<void> _removeFolder(String raw) async {
    final action = await _confirmRegisteredFolderRemoval(raw);
    if (action == null) {
      return;
    }

    if (action == _RegisteredFolderRemovalAction.deleteFiles) {
      final existingItems = await _loadFolderItemsForDeletion(raw);
      final deleted = await widget.repo.deleteItem(
        MediaItem(
          id: raw,
          displayName: _folderLabel(raw),
          kind: MediaKind.folder,
          folderRaw: _registeredFolderParentRaw(raw),
        ),
      );
      if (!mounted) return;
      if (!deleted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('フォルダ本体の削除に失敗しました')));
        return;
      }
      if (existingItems.isNotEmpty) {
        try {
          await widget.tagService.handleDeletedItems(existingItems);
        } catch (_) {}
      }
    }

    await _removeFolderRegistration(raw);
    if (!mounted) return;
    final message = action == _RegisteredFolderRemovalAction.deleteFiles
        ? '登録フォルダと実ファイルを削除しました'
        : '登録フォルダを一覧から削除しました';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _removeFolderRegistration(String raw) async {
    final next = List<String>.from(_foldersRaw)..remove(raw);
    _dirStack.clear();

    String? nextCurrent = _currentFolderRaw;
    if (nextCurrent == raw) {
      nextCurrent = next.isNotEmpty ? next.first : null;
    }

    setState(() {
      _foldersRaw = next.toList(growable: false);
      _currentFolderRaw = nextCurrent;
      _folder = nextCurrent == null ? null : FolderHandle(nextCurrent);
      _items = const [];
      _galleryLoadErrorMessage = null;
    });

    _folderItemsCache.remove(raw);
    await _refreshAllFavoritesItems();
    await _refreshDetailedBrowseIfNeeded();
    await _refreshCurrentPageTags();
    await _refreshArtistTagCounts();

    await _persistFolders();

    if (nextCurrent == null) return;
    await _loadFolder(FolderHandle(nextCurrent), saveAsLast: false);
  }

  Future<_RegisteredFolderRemovalAction?> _confirmRegisteredFolderRemoval(
    String raw,
  ) {
    final canHardDelete = _canHardDeleteRegisteredFolder(raw);
    return showControllerDialog<_RegisteredFolderRemovalAction>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('登録フォルダを削除'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('本当に削除しますか？'),
              const SizedBox(height: 8),
              const Text('登録のみ解除するのか、フォルダ本体と実ファイルまで削除するのかを確認してから実行してください。'),
              const SizedBox(height: 12),
              Text(
                _folderLabel(raw),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                raw,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (!canHardDelete) ...[
                const SizedBox(height: 12),
                const Text('このフォルダでは実ファイル削除は使えないため、登録解除のみ行えます。'),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(
                context,
                _RegisteredFolderRemovalAction.unregisterOnly,
              ),
              child: const Text('登録のみ削除'),
            ),
            if (canHardDelete)
              FilledButton(
                onPressed: () => Navigator.pop(
                  context,
                  _RegisteredFolderRemovalAction.deleteFiles,
                ),
                child: const Text('実ファイルも削除'),
              ),
          ],
        );
      },
    );
  }

  bool _canHardDeleteRegisteredFolder(String raw) {
    if (widget.repo.isRemoteMode || !_repoCapabilities.canDelete) {
      return false;
    }
    if (raw.startsWith('content://') || raw.startsWith('remote://')) {
      return false;
    }
    return Directory(raw).existsSync();
  }

  Future<List<MediaItem>> _loadFolderItemsForDeletion(String raw) async {
    try {
      return await widget.repo.listMediaRecursiveFiles(FolderHandle(raw));
    } catch (_) {
      return const <MediaItem>[];
    }
  }

  String _registeredFolderParentRaw(String raw) {
    if (raw.startsWith('content://') || raw.startsWith('remote://')) {
      return raw;
    }
    try {
      return Directory(raw).parent.path;
    } catch (_) {
      return raw;
    }
  }

  FolderHandle? _activeImportFolder() {
    final activeFolder = _folder;
    if (activeFolder != null) {
      return activeFolder;
    }
    final currentFolderRaw = _currentFolderRaw?.trim();
    if (currentFolderRaw == null || currentFolderRaw.isEmpty) {
      return null;
    }
    return FolderHandle(currentFolderRaw);
  }

  Future<void> _activateImportedFolder(FolderHandle folder) async {
    _dirStack.clear();
    setState(() {
      if (_foldersRaw.contains(folder.raw)) {
        _currentFolderRaw = folder.raw;
      }
      _folder = folder;
      _page = _MainPage.gallery;
    });
    await _persistFolders();
  }

  Future<void> _showFolderTileModeDialog() async {
    final mode = await showControllerDialog<FolderTileMode>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('フォルダ表示設定'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, FolderTileMode.labelOnly),
            child: const Text('フォルダ名のみ（軽量）'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, FolderTileMode.preview),
            child: const Text('プレビュー表示（重め）'),
          ),
        ],
      ),
    );

    if (mode == null) return;
    _saveFolderTileMode(mode);
  }
}
