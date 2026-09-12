part of 'detailImage.dart';

class DetailReaderController {
  // A reader page is a 1600px PNG, so keeping every page visited in a long PDF
  // quickly retains a large amount of compressed and decoded image data.  Keep
  // a small working set instead: the displayed spread and nearby pages remain
  // warm, while distant pages are rendered again only when revisited.
  static const int _readerCacheMaxEntries = 8;
  static const int _thumbCacheMaxEntries = 36;
  static const int _imageCacheMaxEntries = 12;

  final MediaRepository repo;
  final int initialIndex;
  final String? initialPreloadItemId;
  final Future<int>? initialPageCountFuture;
  final Future<Uint8List>? initialReaderBytesFuture;

  Future<Uint8List>? leftFuture;
  Future<Uint8List>? rightFuture;
  bool gifAnimationPaused = false;

  final LinkedHashMap<int, Future<Uint8List>> _readerFutureCache =
      LinkedHashMap<int, Future<Uint8List>>();
  final LinkedHashMap<int, Future<Uint8List>> _staticReaderFutureCache =
      LinkedHashMap<int, Future<Uint8List>>();
  final LinkedHashMap<int, Future<Uint8List>> _thumbFutureCache =
      LinkedHashMap<int, Future<Uint8List>>();
  final LinkedHashMap<String, Future<Uint8List>> _imageFutureCache =
      LinkedHashMap<String, Future<Uint8List>>();
  final _PdfRenderQueue _renderQueue = _PdfRenderQueue(maxConcurrent: 2);

  DetailReaderController({
    required this.repo,
    required this.initialIndex,
    this.initialPreloadItemId,
    this.initialPageCountFuture,
    this.initialReaderBytesFuture,
  });

  void clearCaches() {
    _readerFutureCache.clear();
    _staticReaderFutureCache.clear();
    _thumbFutureCache.clear();
    _imageFutureCache.clear();
    _renderQueue.clearPending();
  }

  void removeReaderPage(int page) {
    _readerFutureCache.remove(page);
    _staticReaderFutureCache.remove(page);
  }

  void removeThumbPage(int page) {
    _thumbFutureCache.remove(page);
  }

  Future<Uint8List> loadReaderBytes(
    MediaItem item,
    int page, {
    required bool useStaticFrame,
    bool prefetch = false,
  }) {
    final cache = useStaticFrame
        ? _staticReaderFutureCache
        : _readerFutureCache;
    final cached = _touch(cache, page);
    if (cached != null) {
      return cached;
    }

    final future = _scheduleCached(
      cache,
      page,
      () => _loadAfterFirstPaint(
        () => useStaticFrame
            ? repo.renderStaticPageBytes(item, page, maxWidth: 1600)
            : repo.renderPageBytes(item, page, maxWidth: 1600),
      ),
      priority: prefetch
          ? _RenderPriority.background
          : _RenderPriority.foreground,
      maxEntries: _readerCacheMaxEntries,
    );
    return future;
  }

  Future<Uint8List> _scheduleCached<K>(
    LinkedHashMap<K, Future<Uint8List>> cache,
    K key,
    Future<Uint8List> Function() load, {
    required _RenderPriority priority,
    required int maxEntries,
  }) {
    final future = _renderQueue.schedule(load, priority: priority);
    cache[key] = future;
    _trim(cache, maxEntries);
    unawaited(
      future.then<void>(
        (_) {},
        onError: (_, _) {
          if (identical(cache[key], future)) {
            cache.remove(key);
          }
        },
      ),
    );
    return future;
  }

  Future<Uint8List>? _touch<K>(
    LinkedHashMap<K, Future<Uint8List>> cache,
    K key,
  ) {
    final future = cache.remove(key);
    if (future != null) {
      cache[key] = future;
    }
    return future;
  }

  void _trim<K>(LinkedHashMap<K, Future<Uint8List>> cache, int maxEntries) {
    while (cache.length > maxEntries) {
      cache.remove(cache.keys.first);
    }
  }

  Future<T> _loadAfterFirstPaint<T>(Future<T> Function() load) async {
    await SchedulerBinding.instance.endOfFrame;
    return load();
  }

  Future<Uint8List> loadThumbBytes(MediaItem item, int page) {
    final cached = _touch(_thumbFutureCache, page);
    if (cached != null) {
      return cached;
    }
    return _scheduleCached(
      _thumbFutureCache,
      page,
      () => repo.renderPageBytes(item, page, maxWidth: 320),
      priority: _RenderPriority.background,
      maxEntries: _thumbCacheMaxEntries,
    );
  }

  Future<Uint8List> loadImageBytes(MediaItem item) {
    final cached = _touch(_imageFutureCache, item.id);
    if (cached != null) {
      return cached;
    }
    return _scheduleCached(
      _imageFutureCache,
      item.id,
      () => _loadAfterFirstPaint(
        () => repo.renderPageBytes(item, 1, maxWidth: 1600),
      ),
      priority: _RenderPriority.foreground,
      maxEntries: _imageCacheMaxEntries,
    );
  }

  bool canUseInitialPreload(MediaItem item, int currentIndex) {
    return item.kind == MediaKind.pdf &&
        currentIndex == initialIndex &&
        initialPreloadItemId == item.id;
  }

  void seedInitialReaderPreload(MediaItem item, int page, int currentIndex) {
    final future = initialReaderBytesFuture;
    if (future == null || !canUseInitialPreload(item, currentIndex)) {
      return;
    }
    _readerFutureCache.putIfAbsent(page, () => future);
  }

  Future<int> getPageCountForCurrent(MediaItem item, int currentIndex) {
    final future = initialPageCountFuture;
    if (future != null && canUseInitialPreload(item, currentIndex)) {
      return future;
    }
    return repo.getPageCount(item);
  }

  void syncFutures({
    required MediaItem item,
    required int page,
    required int totalPages,
    required bool twoPage,
    required bool isPdf,
  }) {
    leftFuture = loadReaderBytes(
      item,
      page,
      useStaticFrame: gifAnimationPaused,
    );

    if (twoPage && isPdf) {
      final nextPage = page + 1;
      rightFuture = nextPage <= totalPages
          ? loadReaderBytes(item, nextPage, useStaticFrame: gifAnimationPaused)
          : null;
      prefetchAdjacentPages(
        item: item,
        page: page,
        totalPages: totalPages,
        twoPage: twoPage,
      );
      return;
    }

    rightFuture = null;
    prefetchAdjacentPages(
      item: item,
      page: page,
      totalPages: totalPages,
      twoPage: twoPage,
    );
  }

  void prefetchAdjacentPages({
    required MediaItem item,
    required int page,
    required int totalPages,
    required bool twoPage,
  }) {
    if (item.kind != MediaKind.pdf || totalPages <= 1) {
      return;
    }

    final pages = <int>{page - 1, page + 1};
    if (twoPage) {
      pages.add(page + 2);
    }

    for (final adjacentPage in pages) {
      if (adjacentPage < 1 || adjacentPage > totalPages) {
        continue;
      }
      unawaited(
        loadReaderBytes(
          item,
          adjacentPage,
          useStaticFrame: gifAnimationPaused,
          prefetch: true,
        ).then<void>((_) {}, onError: (_, _) {}),
      );
    }
  }
}

enum _RenderPriority { foreground, background }

class _PdfRenderQueue {
  final int maxConcurrent;
  final Queue<_QueuedPdfRender> _foreground = Queue<_QueuedPdfRender>();
  final Queue<_QueuedPdfRender> _background = Queue<_QueuedPdfRender>();
  int _activeForeground = 0;
  int _activeBackground = 0;

  _PdfRenderQueue({required this.maxConcurrent});

  Future<Uint8List> schedule(
    Future<Uint8List> Function() operation, {
    required _RenderPriority priority,
  }) {
    final task = _QueuedPdfRender(operation);
    (priority == _RenderPriority.foreground ? _foreground : _background).add(
      task,
    );
    _pump();
    return task.completer.future;
  }

  void clearPending() {
    while (_foreground.isNotEmpty) {
      _foreground.removeFirst().completer.completeError(
        const _PdfRenderCancelled(),
      );
    }
    while (_background.isNotEmpty) {
      _background.removeFirst().completer.completeError(
        const _PdfRenderCancelled(),
      );
    }
  }

  void _pump() {
    while (_activeForeground + _activeBackground < maxConcurrent) {
      if (_foreground.isNotEmpty) {
        _start(_foreground.removeFirst(), _RenderPriority.foreground);
      } else if (_activeBackground == 0 && _background.isNotEmpty) {
        _start(_background.removeFirst(), _RenderPriority.background);
      } else {
        return;
      }
    }
  }

  void _start(_QueuedPdfRender task, _RenderPriority priority) {
    if (priority == _RenderPriority.foreground) {
      _activeForeground++;
    } else {
      _activeBackground++;
    }
    unawaited(() async {
      try {
        task.completer.complete(await task.operation());
      } catch (error, stackTrace) {
        task.completer.completeError(error, stackTrace);
      } finally {
        if (priority == _RenderPriority.foreground) {
          _activeForeground--;
        } else {
          _activeBackground--;
        }
        _pump();
      }
    }());
  }
}

class _QueuedPdfRender {
  final Future<Uint8List> Function() operation;
  final Completer<Uint8List> completer = Completer<Uint8List>();

  _QueuedPdfRender(this.operation);
}

class _PdfRenderCancelled implements Exception {
  const _PdfRenderCancelled();
}
