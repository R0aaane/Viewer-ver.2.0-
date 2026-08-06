// ignore_for_file: invalid_use_of_protected_member, file_names

part of 'detailImage.dart';

extension _ReaderView on _ImageDetailPageState {
  Future<void> _saveTwoPage(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_PrefsKeys.twoPage, v);
  }

  Future<void> _setTwoPageMode(bool value) async {
    if (_twoPage == value) {
      return;
    }
    setState(() {
      _twoPage = value;
      _syncReaderFutures(_item);
    });
    await _saveTwoPage(value);
  }

  Future<void> _setReadingDirection(_ReadingDirection value) async {
    if (_readingDirection == value) return;
    setState(() => _readingDirection = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_PrefsKeys.readingDirection, value.index);
  }

  Future<Uint8List> _loadReaderBytes(MediaItem item, int page) {
    return _readerController.loadReaderBytes(
      item,
      page,
      useStaticFrame: _readerController.gifAnimationPaused,
    );
  }

  Future<Uint8List> _loadThumbBytes(MediaItem item, int page) {
    return _readerController.loadThumbBytes(item, page);
  }

  Future<Uint8List> _loadImageBytes(MediaItem item) {
    return _readerController.loadImageBytes(item);
  }

  Future<EpubTextDocument> _ensureEpubDocument(MediaItem item) {
    if (_epubDocumentFuture != null && _epubDocumentItemId == item.id) {
      return _epubDocumentFuture!;
    }
    _disposeEpubController();
    _epubDocumentFuture = widget.repo
        .readBytes(item)
        .then((bytes) => EpubTextExtractor.parse(bytes));
    _epubDocumentItemId = item.id;
    return _epubDocumentFuture!;
  }

  bool _canUseInitialPreload(MediaItem item) {
    return _readerController.canUseInitialPreload(item, _index);
  }

  void _seedInitialReaderPreload(MediaItem item, int page) {
    _readerController.seedInitialReaderPreload(item, page, _index);
  }

  Future<int> _getPageCountForCurrent(MediaItem item) {
    return _readerController.getPageCountForCurrent(item, _index);
  }

  void _syncReaderFutures(MediaItem item) {
    if (item.kind == MediaKind.epub) {
      _readerController.leftFuture = null;
      _readerController.rightFuture = null;
      return;
    }
    _readerController.syncFutures(
      item: item,
      page: _page,
      totalPages: _totalPages,
      twoPage: _twoPage,
      isPdf: _isPdf,
    );
  }

  void _setCurrentPdfPage(int page) {
    setState(() {
      _hasMovedPdfPageSinceLoad = true;
      _atPdfCompletionPage = false;
      _page = page.clamp(1, _totalPages);
      _syncReaderFutures(_item);
    });
    _schedulePersistCurrentActivity();
  }

  void _toggleGifAnimation() {
    if (!_isPdf) {
      return;
    }
    setState(() {
      _readerController.gifAnimationPaused =
          !_readerController.gifAnimationPaused;
      _syncReaderFutures(_item);
    });
  }

  Future<void> _loadPageCountForCurrent(MediaItem item, int loadVersion) async {
    try {
      final total = await _getPageCountForCurrent(item);
      if (!_isCurrentLoad(loadVersion, item)) return;

      setState(() {
        _totalPages = total < 1 ? 1 : total;
        _page = _page.clamp(1, _totalPages);
        _syncReaderFutures(item);
      });
      _schedulePersistCurrentActivity();
    } catch (error) {
      if (!_isCurrentLoad(loadVersion, item)) return;
      setState(() {
        _totalPages = 1;
        _page = 1;
        _syncReaderFutures(item);
      });
      _schedulePersistCurrentActivity();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('ページ情報の取得に失敗しました: $error')));
    }
  }

  Future<void> _loadReadingProgressForCurrent(
    MediaItem item,
    int loadVersion,
  ) async {
    if (item.kind != MediaKind.pdf) {
      return;
    }

    try {
      final entry = await _readingProgressService.fetchProgressForItem(item);
      if (!_isCurrentLoad(loadVersion, item)) {
        return;
      }

      final progressTotalPages = entry?.totalPages;
      final effectiveTotalPages =
          progressTotalPages != null && progressTotalPages > 0
          ? progressTotalPages
          : _totalPages;
      final nextPage = entry != null && !_hasMovedPdfPageSinceLoad
          ? (entry.isCompleted ? 1 : entry.currentPage)
          : _page;

      setState(() {
        _canPersistReadingProgress = true;
        _isBookmarked = entry?.isBookmarked ?? false;
        if (effectiveTotalPages > 0) {
          _totalPages = effectiveTotalPages;
          _page = nextPage.clamp(1, _totalPages);
        } else {
          _page = nextPage < 1 ? 1 : nextPage;
        }
        _syncReaderFutures(item);
      });
      _schedulePersistCurrentActivity();
    } catch (_) {
      if (!_isCurrentLoad(loadVersion, item)) {
        return;
      }
      setState(() {
        _canPersistReadingProgress = true;
      });
      _schedulePersistCurrentActivity();
    }
  }

  Future<void> _reloadForCurrent() async {
    final item = _item;
    final loadVersion = ++_detailLoadVersion;

    _readerController.clearCaches();
    _loadedTagItemId = null;
    _kemonoVerticalBaseId = null;
    _kemonoVerticalItems = null;
    _kemonoVerticalLoading = false;
    if (mounted) {
      if (!_isEpub) {
        _disposeEpubController();
      }
      final initialPage = item.kind == MediaKind.pdf
          ? (_pendingInitialPdfPage ?? 1)
          : 1;
      _pendingInitialPdfPage = null;
      _seedInitialReaderPreload(item, initialPage < 1 ? 1 : initialPage);
      setState(() {
        _canPersistReadingProgress = item.kind != MediaKind.pdf;
        _hasMovedPdfPageSinceLoad = false;
        _readerController.gifAnimationPaused = false;
        _isFavorite = false;
        _isBookmarked = false;
        _rating = null;
        _tags = const [];
        _relatedItems = const [];
        _relatedItemsLoading = false;
        _relatedItemsForItemId = null;
        _tagsLoading = false;
        if (_tagUsageScopeRaw != item.folderRaw) {
          _tagUsageCounts = <String, int>{};
        }
        _canDeleteFromLibrary =
            widget.repo.capabilities.canDelete && item.kind == MediaKind.pdf;
        _totalPages = 1;
        _page = initialPage < 1 ? 1 : initialPage;
        _atPdfCompletionPage = false;
        _syncReaderFutures(item);
      });
    }

    unawaited(_loadFavoriteForCurrent(loadVersion: loadVersion));
    unawaited(_loadRatingForCurrent(loadVersion: loadVersion));
    unawaited(_loadTagsForCurrent(loadVersion: loadVersion));
    if (item.kind == MediaKind.pdf) {
      unawaited(_loadReadingProgressForCurrent(item, loadVersion));
      unawaited(_loadPageCountForCurrent(item, loadVersion));
    }
    if (!_inReader) {
      _ensureDeferredDetailData();
    }
  }

  Widget _buildLoadError(String message, {required VoidCallback onRetry}) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.cloud_off_outlined,
              color: Colors.white70,
              size: 34,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('再試行'),
            ),
          ],
        ),
      ),
    );
  }

  void _next() {
    if (_isPdf) {
      if (_atPdfCompletionPage) return;
      final step = _twoPage ? 2 : 1;
      final next = _page + step;
      if (next <= _totalPages) {
        _setCurrentPdfPage(next);
      } else {
        _showPdfCompletionPage();
      }
    } else {
      if (_index < _items.length - 1) {
        setState(() {
          _index++;
          _page = 1;
        });
        _pendingInitialPdfPage = 1;
        _reloadForCurrent();
      }
    }
  }

  void _prev() {
    if (_isPdf) {
      if (_atPdfCompletionPage) {
        setState(() => _atPdfCompletionPage = false);
        return;
      }
      final step = _twoPage ? 2 : 1;
      final prev = _page - step;
      if (prev >= 1) {
        _setCurrentPdfPage(prev);
      }
    } else {
      if (_index > 0) {
        setState(() {
          _index--;
          _page = 1;
        });
        _pendingInitialPdfPage = 1;
        _reloadForCurrent();
      }
    }
  }

  void _showPdfCompletionPage() {
    setState(() => _atPdfCompletionPage = true);
    _schedulePersistCurrentActivity();
    _ensureDeferredDetailData();
  }

  Future<void> _toggleFullscreen() async {
    await _setFullscreen(!_fullscreen);
  }

  Future<void> _setFullscreen(bool value) async {
    if (_fullscreen == value) return;
    setState(() => _fullscreen = value);
    if (value) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  Widget _buildReader() {
    if (_leaving) {
      return _buildReaderBusy('閲覧を終了しています...');
    }

    if (_isEpub) {
      return _buildEpubReader(_item);
    }

    if (_isPdf && _atPdfCompletionPage) {
      return _buildPdfCompletionPage();
    }

    if (_isKemonoTaggedImage(_item, _tags)) {
      return _buildKemonoVerticalReader(_item);
    }

    if (_readerController.leftFuture == null) {
      return _buildReaderBusy(_isPdf ? 'PDF を読み込んでいます...' : '読み込んでいます...');
    }

    return Stack(
      children: [
        Center(
          child: LayoutBuilder(
            builder: (context, c) {
              const gap = 0.0;

              final isSpread = _twoPage && _isPdf;
              final pageW = isSpread ? (c.maxWidth - gap) / 2.0 : c.maxWidth;
              final rightToLeft =
                  _readingDirection == _ReadingDirection.rightToLeft;
              final leftPage = isSpread && rightToLeft ? _page + 1 : _page;
              final rightPage = isSpread && !rightToLeft ? _page + 1 : _page;
              final leftFuture = isSpread && rightToLeft
                  ? _readerController.rightFuture
                  : _readerController.leftFuture;
              final rightFuture = isSpread && !rightToLeft
                  ? _readerController.rightFuture
                  : _readerController.leftFuture;

              return Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: pageW,
                    child: _pageImage(
                      leftFuture,
                      align: isSpread
                          ? Alignment.centerRight
                          : Alignment.center,
                      isSpread: isSpread,
                      pageNumber: leftPage,
                    ),
                  ),
                  if (isSpread) ...[
                    const SizedBox(width: gap),
                    SizedBox(
                      width: pageW,
                      child: _pageImage(
                        rightFuture,
                        align: Alignment.centerLeft,
                        isSpread: isSpread,
                        pageNumber: rightPage,
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),

        // Edge taps move PDF pages right-to-left.
        Positioned.fill(
          child: LayoutBuilder(
            builder: (context, c) {
              return GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTapUp: (details) {
                  // Ignore taps outside the reader tab.
                  if (_tab.index != 0) return;

                  final dx = details.localPosition.dx;
                  final w = c.maxWidth;

                  // The center area toggles animation instead of paging.
                  final leftEdge = w * 0.35;
                  final rightEdge = w * 0.65;

                  if (dx < leftEdge) {
                    if (_isPdf) {
                      _readingDirection == _ReadingDirection.rightToLeft
                          ? _next()
                          : _prev();
                    } else {
                      _prev();
                    }
                  } else if (dx > rightEdge) {
                    if (_isPdf) {
                      _readingDirection == _ReadingDirection.rightToLeft
                          ? _prev()
                          : _next();
                    } else {
                      _next();
                    }
                  } else {
                    _toggleGifAnimation();
                  }
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildReaderBusy(String message) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 12),
          Text(message, style: const TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }

  Widget _buildPdfCompletionPage() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(
                Icons.task_alt_outlined,
                color: Colors.amber,
                size: 48,
              ),
              const SizedBox(height: 12),
              Text(
                '読了',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '$_totalPages ページを読み終えました。',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 20),
              _buildRatingSection(),
              const SizedBox(height: 12),
              _buildRelatedItemsSection(),
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: _prev,
                icon: const Icon(Icons.arrow_back),
                label: const Text('最終ページに戻る'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEpubReader(MediaItem item) {
    return FutureBuilder<EpubTextDocument>(
      future: _ensureEpubDocument(item),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _buildLoadError(
            'EPUB を読み込めませんでした。\n${snapshot.error}',
            onRetry: () {
              setState(_disposeEpubController);
            },
          );
        }
        if (!snapshot.hasData) {
          return _buildReaderBusy('EPUB を読み込んでいます...');
        }
        final doc = snapshot.data!;
        if (doc.chapters.isEmpty) {
          return _buildLoadError(
            'EPUB に表示できる本文がありません。',
            onRetry: () {
              setState(_disposeEpubController);
            },
          );
        }
        return Material(
          color: const Color(0xFFFAF8F2),
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            itemCount: doc.chapters.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: Text(
                    doc.title,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: const Color(0xFF211D18),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                );
              }
              final chapter = doc.chapters[index - 1];
              return Padding(
                padding: const EdgeInsets.only(bottom: 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      chapter.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: const Color(0xFF332C24),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      chapter.body,
                      style: const TextStyle(
                        color: Color(0xFF211D18),
                        fontSize: 17,
                        height: 1.65,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  bool _isKemonoTaggedImage(MediaItem item, Iterable<TagWithId> details) {
    if (item.kind != MediaKind.image) {
      return false;
    }
    for (final tag in item.tags) {
      if (_isKemonoTag(tag)) {
        return true;
      }
    }
    for (final detail in details) {
      if (_isKemonoTag(detail.tag)) {
        return true;
      }
    }
    return false;
  }

  bool _isKemonoTag(Tag tag) {
    return tag.name.trim().toLowerCase() == 'kemono';
  }

  Future<void> _loadKemonoVerticalItems(MediaItem base, int loadVersion) async {
    if (_kemonoVerticalBaseId == base.id && _kemonoVerticalItems != null) {
      return;
    }
    if (mounted) {
      setState(() {
        _kemonoVerticalBaseId = base.id;
        _kemonoVerticalLoading = true;
      });
    } else {
      _kemonoVerticalBaseId = base.id;
      _kemonoVerticalLoading = true;
    }

    final candidates = _items
        .where(
          (item) =>
              item.kind == MediaKind.image && item.folderRaw == base.folderRaw,
        )
        .toList(growable: false);

    var verticalItems = candidates
        .where((item) => item.tags.any(_isKemonoTag))
        .toList(growable: false);

    if (verticalItems.length < 2) {
      try {
        final details = await widget.tagService.getDetailedTagsByItems(
          candidates,
        );
        verticalItems = candidates
            .where((item) {
              if (item.id == base.id) {
                return true;
              }
              return (details[item.id] ?? const <TagWithId>[]).any(
                (entry) => _isKemonoTag(entry.tag),
              );
            })
            .toList(growable: false);
      } catch (_) {
        verticalItems = <MediaItem>[base];
      }
    }

    if (!verticalItems.any((item) => item.id == base.id)) {
      verticalItems = <MediaItem>[base, ...verticalItems];
    }

    if (!_isCurrentLoad(loadVersion, base)) {
      return;
    }
    setState(() {
      _kemonoVerticalItems = verticalItems;
      _kemonoVerticalLoading = false;
    });
  }

  Widget _buildKemonoVerticalReader(MediaItem item) {
    final verticalItems = _kemonoVerticalItems;
    if (_kemonoVerticalBaseId != item.id || verticalItems == null) {
      if (!_kemonoVerticalLoading) {
        unawaited(_loadKemonoVerticalItems(item, _detailLoadVersion));
      }
      return _buildReaderBusy('Kemono 縦表示を読み込んでいます...');
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 12),
      itemCount: verticalItems.length,
      itemBuilder: (context, index) {
        final entry = verticalItems[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: FutureBuilder<Uint8List>(
            future: _loadImageBytes(entry),
            builder: (context, snap) {
              if (snap.hasError) {
                return _buildLoadError(
                  '画像の読み込みに失敗しました。\n${snap.error}',
                  onRetry: () => setState(_readerController.clearCaches),
                );
              }
              if (!snap.hasData) {
                return const SizedBox(
                  height: 180,
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final bytes = snap.data!;
              if (bytes.isEmpty) {
                return _buildLoadError(
                  '画像の読み込みに失敗しました。',
                  onRetry: () => setState(_readerController.clearCaches),
                );
              }
              return Image.memory(
                bytes,
                width: double.infinity,
                fit: BoxFit.fitWidth,
                gaplessPlayback: true,
                filterQuality: FilterQuality.high,
              );
            },
          ),
        );
      },
    );
  }

  Widget _pageImage(
    Future<Uint8List>? future, {
    required Alignment align,
    required bool isSpread,
    required int pageNumber,
  }) {
    if (future == null) return const SizedBox.shrink();

    return FutureBuilder<Uint8List>(
      future: future,
      builder: (context, snap) {
        if (snap.hasError) {
          return _buildLoadError(
            '画像の読み込みに失敗しました。\n${snap.error}',
            onRetry: () {
              setState(() {
                _readerController.removeReaderPage(pageNumber);
                _syncReaderFutures(_item);
              });
            },
          );
        }

        if (!snap.hasData) {
          return _buildReaderBusy(_isPdf ? 'PDF ページを読み込んでいます...' : '読み込み中...');
        }
        final bytes = snap.data!;
        if (bytes.isEmpty) {
          return _buildLoadError(
            '画像の読み込みに失敗しました。',
            onRetry: () {
              setState(() {
                _readerController.removeReaderPage(pageNumber);
                _syncReaderFutures(_item);
              });
            },
          );
        }

        final fit = _fullscreen
            ? BoxFit.contain
            : (isSpread ? BoxFit.fitHeight : _boxFit);

        final img = Image.memory(
          bytes,
          fit: fit,
          alignment: align,
          width: _fullscreen ? double.infinity : null,
          height: _fullscreen ? double.infinity : null,
          gaplessPlayback: true,
          filterQuality: FilterQuality.high,
        );

        final widgetToShow = _isPdf && !_fullscreen
            ? DecoratedBox(
                decoration: const BoxDecoration(color: Colors.white),
                child: img,
              )
            : img;
        return InteractiveViewer(
          minScale: 0.5,
          maxScale: 6,
          alignment: align,
          child: _fullscreen
              ? SizedBox.expand(child: widgetToShow)
              : Align(alignment: align, child: widgetToShow),
        );
      },
    );
  }

  Widget _topReaderControls() {
    final canPrev = _isPdf ? (_atPdfCompletionPage || _page > 1) : (_index > 0);
    final canNext = _isPdf
        ? !_atPdfCompletionPage
        : (_index < _items.length - 1);

    final pageText = _isPdf && _atPdfCompletionPage
        ? '読了'
        : _isPdf
        ? '$_page/$_totalPages'
        : '${_index + 1}/${_items.length}';
    final rightToLeft = _readingDirection == _ReadingDirection.rightToLeft;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: _isPdf ? (rightToLeft ? '次' : '前') : '前',
          onPressed: _isPdf
              ? (rightToLeft
                    ? (canNext ? _next : null)
                    : (canPrev ? _prev : null))
              : (canPrev ? _prev : null),
          icon: const Icon(Icons.chevron_left),
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        ),
        IconButton(
          tooltip: _isPdf ? (rightToLeft ? '前' : '次') : '次',
          onPressed: _isPdf
              ? (rightToLeft
                    ? (canPrev ? _prev : null)
                    : (canNext ? _next : null))
              : (canNext ? _next : null),
          icon: const Icon(Icons.chevron_right),
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          margin: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: _ImageDetailPageState._uiChip,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            pageText,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),

        // PDF two-page spread toggle.
        if (_isPdf)
          TextButton.icon(
            style: TextButton.styleFrom(
              foregroundColor: Colors.white,
              backgroundColor: _ImageDetailPageState._uiChip,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              visualDensity: VisualDensity.compact,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            icon: const Icon(Icons.swap_horiz, size: 18),
            label: Text(
              _twoPage ? '見開き ON' : '見開き OFF',
              style: const TextStyle(fontSize: 12),
            ),
            onPressed: () async {
              await _setTwoPageMode(!_twoPage);
            },
          ),

        if (_isPdf) ...[
          const SizedBox(width: 6),
          TextButton.icon(
            style: TextButton.styleFrom(
              foregroundColor: Colors.white,
              backgroundColor: _ImageDetailPageState._uiChip,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              visualDensity: VisualDensity.compact,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            icon: const Icon(Icons.menu_book_outlined, size: 18),
            label: Text(
              rightToLeft ? '右開き' : '左開き',
              style: const TextStyle(fontSize: 12),
            ),
            onPressed: () => _setReadingDirection(
              rightToLeft
                  ? _ReadingDirection.leftToRight
                  : _ReadingDirection.rightToLeft,
            ),
          ),
        ],

        const SizedBox(width: 6),

        // Page selector.
        if (_isPdf)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            decoration: BoxDecoration(
              color: _ImageDetailPageState._uiChip,
              borderRadius: BorderRadius.circular(999),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                value: _page.clamp(1, _totalPages).toInt(),
                isDense: true,
                menuMaxHeight: 360,
                dropdownColor: _ImageDetailPageState._uiBar,
                borderRadius: BorderRadius.circular(14),
                iconEnabledColor: Colors.white,
                style: const TextStyle(color: Colors.white, fontSize: 12),
                selectedItemBuilder: (context) => [
                  for (var page = 1; page <= _totalPages; page++)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'ページ $page',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
                items: [
                  for (var page = 1; page <= _totalPages; page++)
                    DropdownMenuItem<int>(
                      value: page,
                      child: Text('ページ $page'),
                    ),
                ],
                onChanged: _totalPages <= 1
                    ? null
                    : (value) {
                        if (value == null || value == _page) {
                          return;
                        }
                        _setCurrentPdfPage(value);
                      },
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPdfThumbGrid(MediaItem item) {
    final total = _totalPages;

    return SliverGrid(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 0.75,
      ),
      delegate: SliverChildBuilderDelegate((context, i) {
        final page = i + 1;

        return ControllerFocusable(
          debugLabel: 'detail-thumb-$page',
          borderRadius: BorderRadius.circular(10),
          onPressed: () {
            _setCurrentPdfPage(page);
            _tab.animateTo(0);
          },
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: _ImageDetailPageState._uiChip,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: page == _page ? Colors.white : Colors.transparent,
                width: 2,
              ),
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: FutureBuilder<Uint8List>(
                      future: _loadThumbBytes(item, page),
                      builder: (context, snap) {
                        if (snap.hasError) {
                          return _buildLoadError(
                            'ページ $page のサムネイル取得に失敗しました。',
                            onRetry: () {
                              setState(() {
                                _readerController.removeThumbPage(page);
                              });
                            },
                          );
                        }
                        if (!snap.hasData) {
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        }
                        final bytes = snap.data!;
                        if (bytes.isEmpty) {
                          return _buildLoadError(
                            'ページ $page のサムネイル取得に失敗しました。',
                            onRetry: () {
                              setState(() {
                                _readerController.removeThumbPage(page);
                              });
                            },
                          );
                        }
                        return Image.memory(
                          bytes,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          filterQuality: FilterQuality.low,
                        );
                      },
                    ),
                  ),
                ),
                if (widget.repo.capabilities.canEditPdfPages)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Material(
                      color: Colors.black.withValues(alpha: 0.62),
                      borderRadius: BorderRadius.circular(999),
                      child: IconButton(
                        tooltip: '$page ページ目を削除',
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(
                          minWidth: 36,
                          minHeight: 36,
                        ),
                        iconSize: 18,
                        color: Colors.white,
                        icon: const Icon(Icons.delete_outline),
                        onPressed: _totalPages <= 1
                            ? null
                            : () => _deleteCurrentPdfPageWithWarning(
                                pageNumber: page,
                              ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      }, childCount: total),
    );
  }
}

class _PrevIntent extends Intent {
  const _PrevIntent();
}

class _NextIntent extends Intent {
  const _NextIntent();
}

class _ExitFullscreenIntent extends Intent {
  const _ExitFullscreenIntent();
}
