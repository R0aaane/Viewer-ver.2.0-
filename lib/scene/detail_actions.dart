// ignore_for_file: invalid_use_of_protected_member, file_names

part of 'detailImage.dart';

extension _DetailActions on _ImageDetailPageState {
  Future<void> _popWithResult() async {
    if (_leaving) return;
    debugPrint('[detail-back] back pressed item=${_item.id}');
    if (mounted) {
      setState(() {
        _leaving = true;
        _readerController.leftFuture = null;
        _readerController.rightFuture = null;
        _readerController.clearCaches();
      });
      await SchedulerBinding.instance.endOfFrame;
    }
    if (!mounted) return;
    debugPrint('[detail-back] Navigator.pop');
    Navigator.of(context).pop(_favChanged || _tagsChanged || _itemChanged);
  }

  Future<void> _initAsync() async {
    final prefs = await SharedPreferences.getInstance();
    final fitIndex = prefs.getInt(_PrefsKeys.fitMode);
    final two = prefs.getBool(_PrefsKeys.twoPage);
    if (fitIndex != null &&
        fitIndex >= 0 &&
        fitIndex < ReaderFitMode.values.length) {
      _fitMode = ReaderFitMode.values[fitIndex];
    }
    if (two != null) _twoPage = two;
    if (widget.repo.isRemoteMode) {
      _folder = FolderHandle(_item.folderRaw);
    } else {
      final raw = prefs.getString(_PrefsKeys.lastFolderRaw);
      if (raw != null && raw.isNotEmpty) {
        _folder = FolderHandle(raw);
      }
    }
    if (!mounted) return;
    setState(() {});
    _reloadForCurrent();
    unawaited(_loadLibraryContext());
  }

  Future<void> _loadLibraryContext() async {
    try {
      final lib = await widget.repo.getAppLibraryFolder();
      if (!mounted) return;
      setState(() {
        _canDeleteFromLibrary = widget.repo.capabilities.canDelete && _isPdf;
      });
    } catch (_) {}
  }

  Future<void> _loadFavoriteForCurrent({int? loadVersion}) async {
    final item = _item;
    final version = loadVersion ?? _detailLoadVersion;
    final prefs = await SharedPreferences.getInstance();
    var favList = prefs.getStringList(_PrefsKeys.favorites) ?? const <String>[];
    final remoteFavorites = await widget.tagService
        .listRemoteFavoriteIds()
        .catchError((_) => null);
    if (remoteFavorites != null) {
      favList = remoteFavorites.toList(growable: false);
      await prefs.setStringList(_PrefsKeys.favorites, favList);
    }
    final lookupIds = await widget.tagService.favoriteLookupIdsForItem(item);
    final fav = lookupIds.any(favList.contains);
    if (!_isCurrentLoad(version, item)) return;
    setState(() => _isFavorite = fav);
  }

  Future<void> _toggleFavorite() async {
    final prefs = await SharedPreferences.getInstance();
    final favList =
        prefs.getStringList(_PrefsKeys.favorites) ?? const <String>[];
    final next = favList.toSet();
    final lookupIds = await widget.tagService.favoriteLookupIdsForItem(_item);
    final wasFavorite = lookupIds.any(next.contains);

    if (wasFavorite) {
      next.removeAll(lookupIds);
      setState(() => _isFavorite = false);
    } else {
      next.add(_item.id);
      setState(() => _isFavorite = true);
    }

    _favChanged = true;
    final remoteId = await widget.tagService
        .setRemoteFavorite(_item, !wasFavorite)
        .catchError((_) => null);
    if (remoteId != null && remoteId != _item.id) {
      if (next.remove(_item.id)) {
        next.add(remoteId);
      }
    }
    await prefs.setStringList(
      _PrefsKeys.favorites,
      next.toList(growable: false),
    );
  }

  Future<void> _saveLastFolder(FolderHandle folder) async {
    if (widget.repo.isRemoteMode) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_PrefsKeys.lastFolderRaw, folder.raw);
  }

  Future<void> _renameCurrentItem() async {
    final item = _item;
    final newBase = await showRenameItemDialog(context, item: item);

    if (newBase == null || newBase.isEmpty) return;

    try {
      final updated = await widget.repo.rename(item, newBase);
      String? metadataWarning;
      try {
        await widget.tagService.handleItemRenamed(item, updated);
      } catch (e) {
        metadataWarning = 'メタデータの更新に失敗しました: $e';
      }
      final prefs = await SharedPreferences.getInstance();
      final favorites =
          (prefs.getStringList(_PrefsKeys.favorites) ?? const <String>[])
              .toSet();
      if (favorites.remove(item.id)) {
        favorites.add(updated.id);
        await prefs.setStringList(
          _PrefsKeys.favorites,
          favorites.toList(growable: false),
        );
      }
      if (!mounted) return;

      setState(() {
        _items[_index] = updated;
        _isFavorite = favorites.contains(updated.id);
      });
      _itemChanged = true;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('名前を変更しました: ${updated.displayName}')),
      );
      if (metadataWarning != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(metadataWarning)));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('名前の変更に失敗しました: $e')));
    }
  }

  void _schedulePersistCurrentActivity() {
    if (_isPdf && !_canPersistReadingProgress && !_hasMovedPdfPageSinceLoad) {
      return;
    }
    _activityPersistDebounce?.cancel();
    _activityPersistDebounce = Timer(
      const Duration(milliseconds: 350),
      () => unawaited(_persistCurrentActivity()),
    );
  }

  Future<void> _persistCurrentActivity({bool force = false}) async {
    final item = _item;
    if (item.kind != MediaKind.pdf) {
      return;
    }
    if (!force && !_canPersistReadingProgress && !_hasMovedPdfPageSinceLoad) {
      return;
    }
    final page = _twoPage ? (_page + 1).clamp(1, _totalPages) : _page;
    final currentPage = page < 1 ? 1 : page;
    final totalPages = _totalPages > 0 ? _totalPages : null;
    final sw = Stopwatch()..start();
    debugPrint('[detail-back] progress save start item=${item.id}');
    try {
      await _readingProgressService.saveProgressForItem(
        item,
        currentPage: currentPage,
        totalPages: totalPages,
      );
    } catch (error, stackTrace) {
      debugPrint('[detail-back] progress save failed: $error');
      debugPrintStack(
        label: '[detail-back] progress save stack',
        stackTrace: stackTrace,
      );
    } finally {
      debugPrint('[detail-back] progress save end ${sw.elapsedMilliseconds}ms');
    }
  }

  Future<void> _deleteCurrentItemWithWarning() async {
    if (!_canDeleteFromLibrary) return;

    final item = _item;

    final ok = await showControllerDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('この PDF を削除しますか？'),
        content: Text(
          '「${item.displayName}」を削除します。\n'
          '削除すると元に戻せません。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    // 螳溷炎髯､
    final bool deleted;
    try {
      deleted = await widget.repo.deleteItem(item);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('削除に失敗しました: $error')));
      return;
    }
    if (!mounted) return;

    if (!deleted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('削除に失敗しました')));
      return;
    }

    String? metadataWarning;
    try {
      await widget.tagService.handleDeletedItems([item]);
    } catch (e) {
      metadataWarning = 'メタデータ削除に失敗しました: $e';
    }

    // 縺頑ｰ励↓蜈･繧翫↓谿九▲縺ｦ繧九→繧ｴ繝溘↓縺ｪ繧九・縺ｧ螟悶☆
    final prefs = await SharedPreferences.getInstance();
    final fav = (prefs.getStringList(_PrefsKeys.favorites) ?? const <String>[])
        .toSet();
    fav.remove(item.id);
    await prefs.setStringList(
      _PrefsKeys.favorites,
      fav.toList(growable: false),
    );

    if (metadataWarning != null && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(metadataWarning)));
    }

    // 隧ｳ邏ｰ逕ｻ髱｢繧帝哩縺倥※荳隕ｧ蛛ｴ縺ｧ繝ｪ繝ｭ繝ｼ繝峨＆縺帙ｋ
    if (!mounted) return;
    Navigator.pop(context, true);
  }
}
