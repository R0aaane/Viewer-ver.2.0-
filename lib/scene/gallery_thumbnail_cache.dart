// ignore_for_file: file_names, invalid_use_of_protected_member

part of 'gridGallery.dart';

extension _GalleryThumbnailCache on _GalleryGridPageState {
  Future<void> _acquireFolderPreviewSlot([int max = 1]) async {
    if (_folderPreviewActive < max) {
      _folderPreviewActive++;
      return;
    }
    final c = Completer<void>();
    _folderPreviewWaiters.add(c);
    await c.future;
    _folderPreviewActive++;
  }

  void _releaseFolderPreviewSlot() {
    _folderPreviewActive--;
    if (_folderPreviewWaiters.isNotEmpty) {
      _folderPreviewWaiters.removeAt(0).complete();
    }
  }

  Future<void> _acquireMediaThumbSlot([int max = 2]) async {
    if (_mediaThumbActive < max) {
      _mediaThumbActive++;
      return;
    }
    final c = Completer<void>();
    _mediaThumbWaiters.add(c);
    await c.future;
    _mediaThumbActive++;
  }

  void _releaseMediaThumbSlot() {
    _mediaThumbActive--;
    if (_mediaThumbWaiters.isNotEmpty) {
      _mediaThumbWaiters.removeAt(0).complete();
    }
  }

  Uint8List? _folderPreviewCacheGet(String key) {
    final v = _folderPreviewCache.remove(key);
    if (v == null && !_folderPreviewCache.containsKey(key)) return null;
    _folderPreviewCache[key] = v;
    return v;
  }

  void _folderPreviewCachePut(String key, Uint8List? bytes) {
    final old = _folderPreviewCache.remove(key);
    if (old != null) _folderPreviewCacheBytes -= old.lengthInBytes;

    _folderPreviewCache[key] = bytes;
    if (bytes != null) _folderPreviewCacheBytes += bytes.lengthInBytes;

    while (_folderPreviewCache.isNotEmpty &&
        (_folderPreviewCache.length >
                _GalleryGridPageState._folderPreviewCacheMaxEntries ||
            _folderPreviewCacheBytes >
                _GalleryGridPageState._folderPreviewCacheMaxBytes)) {
      final oldestKey = _folderPreviewCache.keys.first;
      final oldestVal = _folderPreviewCache.remove(oldestKey);
      if (oldestVal != null) {
        _folderPreviewCacheBytes -= oldestVal.lengthInBytes;
      }
    }
  }

  String _mediaThumbCacheKey(MediaItem item) {
    final modified = item.modified?.millisecondsSinceEpoch ?? 0;
    final size = item.sizeBytes ?? -1;
    return '${item.id}|$modified|$size|$_GalleryGridPageState._mediaThumbMaxWidth';
  }

  ThumbPair? _mediaThumbCacheGet(String key) {
    final pair = _mediaThumbCache.remove(key);
    if (pair == null) return null;
    _mediaThumbCache[key] = pair;
    return pair;
  }

  void _mediaThumbCachePut(String key, ThumbPair pair) {
    final old = _mediaThumbCache.remove(key);
    if (old != null) {
      _mediaThumbCacheBytes -=
          old.front.lengthInBytes + (old.back?.lengthInBytes ?? 0);
    }

    _mediaThumbCache[key] = pair;
    _mediaThumbCacheBytes +=
        pair.front.lengthInBytes + (pair.back?.lengthInBytes ?? 0);

    while (_mediaThumbCache.isNotEmpty &&
        (_mediaThumbCache.length >
                _GalleryGridPageState._mediaThumbCacheMaxEntries ||
            _mediaThumbCacheBytes >
                _GalleryGridPageState._mediaThumbCacheMaxBytes)) {
      final oldestKey = _mediaThumbCache.keys.first;
      final oldest = _mediaThumbCache.remove(oldestKey);
      if (oldest != null) {
        _mediaThumbCacheBytes -=
            oldest.front.lengthInBytes + (oldest.back?.lengthInBytes ?? 0);
      }
    }
  }

  Future<ThumbPair> _getMediaThumbPair(MediaItem item) {
    final key = _mediaThumbCacheKey(item);
    final cached = _mediaThumbCacheGet(key);
    if (cached != null) return Future.value(cached);

    final inFlight = _mediaThumbInFlight[key];
    if (inFlight != null) return inFlight;

    final future =
        (() async {
          await _acquireMediaThumbSlot();
          try {
            final pair = await widget.repo.readThumbPair(
              item,
              maxWidth: _GalleryGridPageState._mediaThumbMaxWidth,
            );
            _mediaThumbCachePut(key, pair);
            return pair;
          } finally {
            _releaseMediaThumbSlot();
          }
        })().whenComplete(() {
          _mediaThumbInFlight.remove(key);
        });

    _mediaThumbInFlight[key] = future;
    return future;
  }

  void _prepareVisibleMedia(List<MediaItem> items) {
    final generation = ++_visiblePrepareGeneration;
    final visible = items
        .where(
          (item) => item.kind != MediaKind.folder && item.kind != MediaKind.epub,
        )
        .toList(growable: false);
    if (visible.isEmpty) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(() async {
        await Future<void>.delayed(const Duration(milliseconds: 80));
        for (final item in visible) {
          if (!mounted || generation != _visiblePrepareGeneration) return;
          unawaited(
            _getMediaThumbPair(item).catchError((_) {
              return ThumbPair(front: Uint8List(0), back: null);
            }),
          );
        }

        for (final item in visible) {
          if (!mounted || generation != _visiblePrepareGeneration) return;
          if (item.kind != MediaKind.pdf) continue;
          try {
            await widget.repo.getPageCount(item);
          } catch (_) {
            // Ignore background warm-up failures; foreground open still reports.
          }
        }
      }());
    });
  }

  Future<Uint8List?> _getFolderPreviewBytes(MediaItem folderItem) {
    //if (!_thumbsEnabled) return Future.value(null);

    final key = folderItem.id;

    if (_folderPreviewCache.containsKey(key)) {
      return Future.value(_folderPreviewCacheGet(key));
    }

    final inflight = _folderPreviewInFlight[key];
    if (inflight != null) return inflight;

    Future<MediaItem?> pickCandidateInFolder(String folderRaw) async {
      const int pageLimit = 60;
      const int maxPages = 4;

      MediaItem? firstImage;

      for (int p = 0; p < maxPages; p++) {
        final res = await widget.repo.listMediaPage(
          FolderHandle(folderRaw),
          offset: p * pageLimit,
          limit: pageLimit,
        );

        for (final it in res.items) {
          if (it.kind == MediaKind.pdf) return it; // PDF蜆ｪ蜈・
          if (it.kind == MediaKind.image && firstImage == null) {
            firstImage = it;
          }
        }

        if (res.items.length < pageLimit) break;
      }

      return firstImage;
    }

    final fut = () async {
      await _acquireFolderPreviewSlot(1);
      try {
        final cand = await pickCandidateInFolder(folderItem.id);
        if (cand != null) {
          final pair = await _getMediaThumbPair(cand);
          _folderPreviewCachePut(key, pair.front);
          return pair.front;
        }

        final firstPage = await widget.repo.listMediaPage(
          FolderHandle(folderItem.id),
          offset: 0,
          limit: 60,
        );

        int tried = 0;
        for (final it in firstPage.items) {
          if (it.kind != MediaKind.folder) continue;
          final cand2 = await pickCandidateInFolder(it.id);
          if (cand2 != null) {
            final pair = await _getMediaThumbPair(cand2);
            _folderPreviewCachePut(key, pair.front);
            return pair.front;
          }
          tried++;
          if (tried >= 3) break;
        }

        _folderPreviewCachePut(key, null);
        return null;
      } catch (_) {
        _folderPreviewCachePut(key, null);
        return null;
      } finally {
        _releaseFolderPreviewSlot();
        _folderPreviewInFlight.remove(key);
      }
    }();

    _folderPreviewInFlight[key] = fut;
    return fut;
  }
}
