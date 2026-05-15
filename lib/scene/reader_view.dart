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
        _tags = const [];
        _tagsLoading = false;
        if (_tagUsageScopeRaw != item.folderRaw) {
          _tagUsageCounts = <String, int>{};
        }
        _canDeleteFromLibrary =
            widget.repo.capabilities.canDelete && item.kind == MediaKind.pdf;
        _totalPages = 1;
        _page = initialPage < 1 ? 1 : initialPage;
        _syncReaderFutures(item);
      });
    }

    unawaited(_loadFavoriteForCurrent(loadVersion: loadVersion));
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
      final step = _twoPage ? 2 : 1;
      final next = _page + step;
      if (next <= _totalPages) {
        _setCurrentPdfPage(next);
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

              return Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: pageW,
                    child: _pageImage(
                      _readerController.leftFuture,
                      align: isSpread
                          ? Alignment.centerRight
                          : Alignment.center,
                      isSpread: isSpread,
                      pageNumber: _page,
                    ),
                  ),
                  if (isSpread) ...[
                    const SizedBox(width: gap),
                    SizedBox(
                      width: pageW,
                      child: _pageImage(
                        _readerController.rightFuture,
                        align: Alignment.centerLeft,
                        isSpread: isSpread,
                        pageNumber: _page + 1,
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),

        // 遶ｯ譛ｫ繧ｿ繝・・縺ｧ繝壹・繧ｸ驕ｷ遘ｻ・亥ｷｦ=蜑・/ 蜿ｳ=谺｡・・
        Positioned.fill(
          child: LayoutBuilder(
            builder: (context, c) {
              return GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTapUp: (details) {
                  // 髢ｲ隕ｧ逕ｨ繧ｿ繝紋ｻ･螟悶・辟｡隕悶☆繧・
                  if (_tab.index != 0) return;

                  final dx = details.localPosition.dx;
                  final w = c.maxWidth;

                  // 荳ｭ螟ｮ縺ｯ辟｡蜿榊ｿ懊↓
                  final leftEdge = w * 0.35;
                  final rightEdge = w * 0.65;

                  if (dx < leftEdge) {
                    _prev();
                  } else if (dx > rightEdge) {
                    _next();
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

        // 隕矩幕縺阪・縲檎ｸｦ蜷医ｏ縺帙搾ｼ九檎ｶｴ縺伜・蟇・○縲阪′荳逡ｪ螳牙ｮ壹＠繧・☆縺九▲縺・
        final fit = _fullscreen
            ? BoxFit.contain
            : (isSpread ? BoxFit.fitHeight : _boxFit);

        //pdf縺ｮ閭梧勹縺ｫ逋ｽ繧定ｿｽ蜉・磯乗・縺ｧ騾上￠縺ｦ隕九∴繧具ｼ・
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
    final canPrev = _isPdf ? (_page > 1) : (_index > 0);
    final canNext = _isPdf
        ? (_page + (_twoPage ? 2 : 1) <= _totalPages)
        : (_index < _items.length - 1);

    final pageText = _isPdf
        ? '$_page/$_totalPages'
        : '${_index + 1}/${_items.length}';

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: '前',
          onPressed: canPrev ? _prev : null,
          icon: const Icon(Icons.chevron_left),
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        ),
        IconButton(
          tooltip: '谺｡',
          onPressed: canNext ? _next : null,
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

        // 隕矩幕縺阪・PDF縺縺・
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

        const SizedBox(width: 6),

        // Fit ・亥・菴薙ｒ陦ｨ遉ｺ縺吶ｋ繝｢繝ｼ繝会ｼ・
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
                    return const Center(child: CircularProgressIndicator());
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
