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
    Navigator.of(
      context,
    ).pop(_favChanged || _ratingChanged || _tagsChanged || _itemChanged);
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
      await widget.repo.getAppLibraryFolder();
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

  Map<String, int> _decodeRatings(String? raw) {
    if (raw == null || raw.isEmpty) return <String, int>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, int>{};
      final ratings = <String, int>{};
      for (final entry in decoded.entries) {
        final key = entry.key?.toString();
        final value = entry.value;
        final rating = value is int ? value : int.tryParse(value.toString());
        if (key == null || rating == null || rating < 3 || rating > 5) {
          continue;
        }
        ratings[key] = rating;
      }
      return ratings;
    } catch (_) {
      return <String, int>{};
    }
  }

  Future<void> _loadRatingForCurrent({int? loadVersion}) async {
    final item = _item;
    final version = loadVersion ?? _detailLoadVersion;
    final prefs = await SharedPreferences.getInstance();
    var ratings = _decodeRatings(prefs.getString(_PrefsKeys.ratingsJson));
    final remoteRatings = await widget.tagService
        .listRemoteRatings()
        .catchError((_) => null);
    if (remoteRatings != null) {
      ratings = remoteRatings;
      await prefs.setString(_PrefsKeys.ratingsJson, jsonEncode(ratings));
    }
    final lookupIds = await widget.tagService.favoriteLookupIdsForItem(item);
    int? rating;
    for (final id in lookupIds) {
      rating = ratings[id];
      if (rating != null) break;
    }
    if (!_isCurrentLoad(version, item)) return;
    setState(() => _rating = rating);
  }

  Future<void> _setRating(int? rating) async {
    if (rating != null && (rating < 3 || rating > 5)) return;
    final prefs = await SharedPreferences.getInstance();
    final ratings = _decodeRatings(prefs.getString(_PrefsKeys.ratingsJson));
    if (rating == null) {
      ratings.remove(_item.id);
    } else {
      ratings[_item.id] = rating;
    }
    final remoteId = await widget.tagService
        .setRemoteRating(_item, rating)
        .catchError((_) => null);
    if (remoteId != null && remoteId != _item.id) {
      if (rating == null) {
        ratings.remove(remoteId);
      } else if (ratings.remove(_item.id) != null) {
        ratings[remoteId] = rating;
      }
    }
    await prefs.setString(_PrefsKeys.ratingsJson, jsonEncode(ratings));
    if (!mounted) return;
    setState(() => _rating = rating);
    _ratingChanged = true;
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

  Future<void> _toggleBookmark() async {
    if (!_isPdf) return;
    final next = !_isBookmarked;
    setState(() => _isBookmarked = next);
    try {
      await _readingProgressService.saveProgressForItem(
        _item,
        currentPage: _page < 1 ? 1 : _page,
        totalPages: _totalPages > 0 ? _totalPages : null,
        isBookmarked: next,
      );
      _itemChanged = true;
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(next ? 'しおりを挟みました' : 'しおりを外しました')));
    } catch (error) {
      if (!mounted) return;
      setState(() => _isBookmarked = !next);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('しおりの更新に失敗しました: $error')));
    }
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
      final ratings = _decodeRatings(prefs.getString(_PrefsKeys.ratingsJson));
      final rating = ratings.remove(item.id);
      if (rating != null) {
        ratings[updated.id] = rating;
        await prefs.setString(_PrefsKeys.ratingsJson, jsonEncode(ratings));
      }
      if (!mounted) return;

      setState(() {
        _items[_index] = updated;
        _isFavorite = favorites.contains(updated.id);
        _rating = rating;
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
    final ratings = _decodeRatings(prefs.getString(_PrefsKeys.ratingsJson));
    ratings.remove(item.id);
    await prefs.setString(_PrefsKeys.ratingsJson, jsonEncode(ratings));

    if (metadataWarning != null && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(metadataWarning)));
    }

    // 隧ｳ邏ｰ逕ｻ髱｢繧帝哩縺倥※荳隕ｧ蛛ｴ縺ｧ繝ｪ繝ｭ繝ｼ繝峨＆縺帙ｋ
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  Future<void> _deleteCurrentPdfPageWithWarning({int? pageNumber}) async {
    if (!_isPdf || !widget.repo.capabilities.canEditPdfPages) return;
    if (_totalPages <= 1) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('最後の1ページは削除できません')));
      return;
    }

    final item = _item;
    final page = (pageNumber ?? _page).clamp(1, _totalPages);
    final ok = await showControllerDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('このページを削除しますか？'),
        content: Text(
          '「${item.displayName}」の $page ページ目を削除します。\n'
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

    try {
      final updated = await widget.repo.deletePdfPage(item, page);
      if (!mounted) return;

      setState(() {
        _items[_index] = updated;
        _totalPages = (_totalPages - 1).clamp(1, _totalPages);
        _page = page.clamp(1, _totalPages);
        _readerController.clearCaches();
        _syncReaderFutures(updated);
      });
      _itemChanged = true;
      _schedulePersistCurrentActivity();

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$page ページ目を削除しました')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('ページ削除に失敗しました: $error')));
    }
  }
}
