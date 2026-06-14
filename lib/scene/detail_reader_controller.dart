part of 'detailImage.dart';

class DetailReaderController {
  final MediaRepository repo;
  final int initialIndex;
  final String? initialPreloadItemId;
  final Future<int>? initialPageCountFuture;
  final Future<Uint8List>? initialReaderBytesFuture;

  Future<Uint8List>? leftFuture;
  Future<Uint8List>? rightFuture;
  bool gifAnimationPaused = false;

  final Map<int, Future<Uint8List>> _readerFutureCache =
      <int, Future<Uint8List>>{};
  final Map<int, Future<Uint8List>> _staticReaderFutureCache =
      <int, Future<Uint8List>>{};
  final Map<int, Future<Uint8List>> _thumbFutureCache =
      <int, Future<Uint8List>>{};
  final Map<String, Future<Uint8List>> _imageFutureCache =
      <String, Future<Uint8List>>{};

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
  }) {
    if (useStaticFrame) {
      return _staticReaderFutureCache.putIfAbsent(page, () {
        return _loadAfterFirstPaint(
          () => repo.renderStaticPageBytes(item, page, maxWidth: 1600),
        );
      });
    }
    return _readerFutureCache.putIfAbsent(page, () {
      return _loadAfterFirstPaint(
        () => repo.renderPageBytes(item, page, maxWidth: 1600),
      );
    });
  }

  Future<T> _loadAfterFirstPaint<T>(Future<T> Function() load) async {
    await SchedulerBinding.instance.endOfFrame;
    return load();
  }

  Future<Uint8List> loadThumbBytes(MediaItem item, int page) {
    return _thumbFutureCache.putIfAbsent(page, () {
      return repo.renderPageBytes(item, page, maxWidth: 320);
    });
  }

  Future<Uint8List> loadImageBytes(MediaItem item) {
    return _imageFutureCache.putIfAbsent(item.id, () {
      return _loadAfterFirstPaint(
        () => repo.renderPageBytes(item, 1, maxWidth: 1600),
      );
    });
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
        ).then<void>((_) {}, onError: (_, _) {}),
      );
    }
  }
}
