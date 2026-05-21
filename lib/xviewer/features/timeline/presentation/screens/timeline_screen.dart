import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/constants/app_routes.dart';
import '../../../../app/xviewer_shell_controller.dart';
import '../../../../core/constants/storage_keys.dart';
import '../../../../domain/models/feed_mode.dart';
import '../../../../domain/models/media_post.dart';
import '../../../../domain/models/post_image.dart';
import '../../../../domain/models/save_failure_reason.dart';
import '../../../../services/service_providers.dart';
import '../../../../widgets/async_value_view.dart';
import '../../../../widgets/post_media_card.dart';
import '../../../../widgets/section_empty_view.dart';
import '../../../auth/presentation/providers/auth_controller.dart';
import '../../../saved/presentation/providers/saved_media_controller.dart';
import '../../../settings/presentation/providers/app_preferences_controller.dart';
import '../../../settings/presentation/widgets/app_preferences_dialog.dart';
import '../providers/timeline_controller.dart';

class TimelineScreen extends ConsumerStatefulWidget {
  const TimelineScreen({super.key});

  @override
  ConsumerState<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends ConsumerState<TimelineScreen> {
  static const double _defaultGridItemExtent = 148;
  static const double _minGridItemExtent = 112;
  static const double _maxGridItemExtent = 220;

  final GlobalKey _gridAreaKey = GlobalKey();
  final Map<String, GlobalKey> _tileKeys = <String, GlobalKey>{};
  final ValueNotifier<_BatchSaveProgress> _batchSaveProgressNotifier =
      ValueNotifier(const _BatchSaveProgress.idle());

  double _gridItemExtent = _defaultGridItemExtent;
  bool _isSelectionMode = false;
  bool _dragSelecting = false;
  String? _dragSelectionAnchorId;
  Set<String> _selectedIds = <String>{};
  Map<String, TimelineEntry> _visibleEntriesById =
      const <String, TimelineEntry>{};

  @override
  void initState() {
    super.initState();
    _loadGridPreferences();
  }

  @override
  void dispose() {
    _batchSaveProgressNotifier.dispose();
    super.dispose();
  }

  Future<void> _loadGridPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final storedExtent = prefs.getDouble(StorageKeys.galleryGridItemExtent);
    if (!mounted || storedExtent == null) {
      return;
    }

    setState(() {
      _gridItemExtent = _clampGridItemExtent(storedExtent);
    });
  }

  Future<void> _setGridItemExtent(double value) async {
    final nextValue = _clampGridItemExtent(value);
    if (!mounted) {
      return;
    }

    setState(() {
      _gridItemExtent = nextValue;
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(StorageKeys.galleryGridItemExtent, nextValue);
  }

  double _clampGridItemExtent(double value) {
    return value.clamp(_minGridItemExtent, _maxGridItemExtent).toDouble();
  }

  String _gridSizeLabel(double value) {
    if (value <= 132) {
      return 'Small';
    }
    if (value >= 188) {
      return 'Large';
    }
    return 'Medium';
  }

  Future<void> _showGridSizeDialog() async {
    var draftValue = _gridItemExtent;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Display size'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${_gridSizeLabel(draftValue)} (${draftValue.round()} px)',
                  ),
                  const SizedBox(height: 12),
                  Slider(
                    value: draftValue,
                    min: _minGridItemExtent,
                    max: _maxGridItemExtent,
                    divisions: (_maxGridItemExtent - _minGridItemExtent)
                        .round(),
                    label: _gridSizeLabel(draftValue),
                    onChanged: (value) {
                      setDialogState(() {
                        draftValue = value;
                      });
                      _setGridItemExtent(value);
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    setDialogState(() {
                      draftValue = _defaultGridItemExtent;
                    });
                    _setGridItemExtent(_defaultGridItemExtent);
                  },
                  child: const Text('Reset'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Close'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showAppPreferencesDialog() async {
    await showDialog<void>(
      context: context,
      builder: (context) => const AppPreferencesDialog(),
    );
  }

  Future<void> _showImagePreview(TimelineEntry entry) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return Dialog(
          clipBehavior: Clip.antiAlias,
          insetPadding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960, maxHeight: 720),
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 72),
                  child: InteractiveViewer(
                    minScale: 0.8,
                    maxScale: 4,
                    child: Center(
                      child: Image.network(
                        entry.image.imageUrl,
                        fit: BoxFit.contain,
                        loadingBuilder: (context, child, progress) {
                          if (progress == null) {
                            return child;
                          }
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        },
                        errorBuilder: (context, error, stackTrace) {
                          return const ColoredBox(
                            color: Color(0xFFE5E7EB),
                            child: Center(
                              child: Icon(Icons.broken_image_outlined),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: IconButton.filled(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    icon: const Icon(Icons.close_rounded),
                    tooltip: 'Close preview',
                  ),
                ),
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 16,
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              entry.post.authorName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            Text(
                              '@${entry.post.authorUsername}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton.tonalIcon(
                        onPressed: () async {
                          Navigator.of(dialogContext).pop();
                          await _openPost(entry.post);
                        },
                        icon: const Icon(Icons.open_in_new_rounded),
                        label: const Text('Open post'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openPost(MediaPost post) async {
    try {
      await ref
          .read(linkLauncherServiceProvider)
          .openExternal(post.originalPostUrl);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _saveImage(TimelineEntry entry) async {
    try {
      final result = await ref
          .read(savedMediaControllerProvider.notifier)
          .saveImage(post: entry.post, image: entry.image);
      if (!mounted) {
        return;
      }
      final message = switch (result.failureReason) {
        SaveFailureReason.duplicate => 'This image is already saved',
        SaveFailureReason.permissionDenied =>
          'Gallery permission was denied, so the image was kept in app storage',
        SaveFailureReason.galleryUnavailable =>
          'Saved in app storage because gallery save was unavailable',
        SaveFailureReason.unsupportedPlatform =>
          'Saved in app storage on this platform',
        SaveFailureReason.writeFailed =>
          'Gallery save failed, so the image was kept in app storage',
        _ => result.message ?? 'Saved to ${result.locationType.name}',
      };
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Save failed: $error')));
    }
  }

  void _enterSelectionMode(String id) {
    if (!mounted) {
      return;
    }
    setState(() {
      _isSelectionMode = true;
      _dragSelecting = true;
      _dragSelectionAnchorId = id;
      _selectedIds = {..._selectedIds, id};
    });
  }

  void _toggleSelection(String id) {
    if (!mounted) {
      return;
    }
    setState(() {
      final next = {..._selectedIds};
      if (!next.add(id)) {
        next.remove(id);
      }
      _selectedIds = next;
      if (_selectedIds.isEmpty) {
        _isSelectionMode = false;
        _dragSelecting = false;
        _dragSelectionAnchorId = null;
      }
    });
  }

  void _clearSelection() {
    if (!mounted) {
      return;
    }
    setState(() {
      _isSelectionMode = false;
      _selectedIds = <String>{};
      _dragSelectionAnchorId = null;
      _dragSelecting = false;
    });
  }

  void _selectAllVisible() {
    if (!mounted) {
      return;
    }
    setState(() {
      _isSelectionMode = true;
      _selectedIds = _visibleEntriesById.keys.toSet();
    });
  }

  Future<void> _saveSelectedItems() async {
    final selectedEntries = _selectedIds
        .map((id) => _visibleEntriesById[id])
        .whereType<TimelineEntry>()
        .toList(growable: false);
    if (selectedEntries.isEmpty) {
      return;
    }

    _batchSaveProgressNotifier.value = _BatchSaveProgress(
      current: 0,
      total: selectedEntries.length,
      successCount: 0,
      failureCount: 0,
      inProgress: true,
    );

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => ValueListenableBuilder<_BatchSaveProgress>(
        valueListenable: _batchSaveProgressNotifier,
        builder: (context, progress, _) {
          return AlertDialog(
            title: const Text('Saving selected images'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${progress.current} / ${progress.total} saving'),
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  value: progress.total == 0
                      ? null
                      : progress.current / progress.total,
                ),
                const SizedBox(height: 12),
                Text('Success: ${progress.successCount}'),
                Text('Failed: ${progress.failureCount}'),
              ],
            ),
          );
        },
      ),
    );

    var successCount = 0;
    var failureCount = 0;

    for (var index = 0; index < selectedEntries.length; index++) {
      final entry = selectedEntries[index];
      try {
        final result = await ref
            .read(savedMediaControllerProvider.notifier)
            .saveImage(post: entry.post, image: entry.image);
        if (result.isSuccess ||
            result.failureReason == SaveFailureReason.duplicate) {
          successCount++;
        } else {
          failureCount++;
        }
      } catch (_) {
        failureCount++;
      }

      _batchSaveProgressNotifier.value = _BatchSaveProgress(
        current: index + 1,
        total: selectedEntries.length,
        successCount: successCount,
        failureCount: failureCount,
        inProgress: true,
      );
    }

    _batchSaveProgressNotifier.value = _BatchSaveProgress(
      current: selectedEntries.length,
      total: selectedEntries.length,
      successCount: successCount,
      failureCount: failureCount,
      inProgress: false,
    );

    if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Saved $successCount items, failed $failureCount items'),
      ),
    );
    _clearSelection();
  }

  String? _hitTestGridItem(Offset globalPosition) {
    for (final entry in _tileKeys.entries) {
      final context = entry.value.currentContext;
      if (context == null) {
        continue;
      }
      final renderObject = context.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.hasSize) {
        continue;
      }
      final topLeft = renderObject.localToGlobal(Offset.zero);
      final rect = topLeft & renderObject.size;
      if (rect.contains(globalPosition)) {
        return entry.key;
      }
    }
    return null;
  }

  GlobalKey _tileKeyFor(String id) {
    return _tileKeys.putIfAbsent(id, GlobalKey.new);
  }

  void _handleDragSelectionAt(Offset globalPosition) {
    if (!_isSelectionMode || !_dragSelecting) {
      return;
    }
    final hitId = _hitTestGridItem(globalPosition);
    if (hitId == null ||
        hitId == _dragSelectionAnchorId ||
        _selectedIds.contains(hitId)) {
      return;
    }
    setState(() {
      _selectedIds = {..._selectedIds, hitId};
      _dragSelectionAnchorId = hitId;
    });
  }

  void _finishDragSelection() {
    if (!_dragSelecting) {
      return;
    }
    setState(() {
      _dragSelecting = false;
      _dragSelectionAnchorId = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final timelineState = ref.watch(timelineControllerProvider);
    final savedState = ref.watch(savedMediaControllerProvider);
    final savedItemsLabel = ref.watch(
      appPreferencesProvider.select((value) => value.savedItemsLabel),
    );
    final savedMediaKeys =
        savedState.valueOrNull?.map((record) => record.mediaKey).toSet() ??
        <String>{};
    final closeXViewer = ref.watch(xViewerCloseHandlerProvider);

    return Scaffold(
      appBar: _isSelectionMode
          ? AppBar(
              leading: IconButton(
                onPressed: _clearSelection,
                icon: const Icon(Icons.close_rounded),
                tooltip: 'Exit selection mode',
              ),
              title: Text('${_selectedIds.length} selected'),
              actions: [
                IconButton(
                  onPressed: _visibleEntriesById.isEmpty
                      ? null
                      : _selectAllVisible,
                  icon: const Icon(Icons.select_all_rounded),
                  tooltip: 'Select all',
                ),
                IconButton(
                  onPressed: _selectedIds.isEmpty ? null : _clearSelection,
                  icon: const Icon(Icons.clear_all_rounded),
                  tooltip: 'Clear selection',
                ),
                IconButton(
                  onPressed: _selectedIds.isEmpty ? null : _saveSelectedItems,
                  icon: const Icon(Icons.download_rounded),
                  tooltip: 'Save selected',
                ),
              ],
            )
          : AppBar(
              leading: closeXViewer == null
                  ? null
                  : IconButton(
                      onPressed: closeXViewer,
                      icon: const Icon(Icons.arrow_back_rounded),
                      tooltip: 'Back to pdf_viewer',
                    ),
              title: const Text('X Image Feed'),
              actions: [
                IconButton(
                  onPressed: _showGridSizeDialog,
                  icon: const Icon(Icons.grid_view_rounded),
                  tooltip: 'Display size',
                ),
                IconButton(
                  onPressed: () => context.go(AppRoutes.saved),
                  icon: const Icon(Icons.bookmark_rounded),
                  tooltip: savedItemsLabel,
                ),
                IconButton(
                  onPressed: _showAppPreferencesDialog,
                  icon: const Icon(Icons.tune_rounded),
                  tooltip: 'Display settings',
                ),
                IconButton(
                  onPressed: () async {
                    await ref.read(authControllerProvider.notifier).signOut();
                    if (context.mounted) {
                      context.go(AppRoutes.login);
                    }
                  },
                  icon: const Icon(Icons.logout_rounded),
                  tooltip: 'Sign out',
                ),
              ],
            ),
      body: AsyncValueView(
        value: timelineState,
        loadingLabel: 'Loading image posts...',
        onRetry: () => ref.invalidate(timelineControllerProvider),
        data: (screenState) {
          final selectedMode = screenState.selectedMode;
          final feed = screenState.feedStateFor(selectedMode);
          final items = _flattenPosts(feed.items);
          _visibleEntriesById = {
            for (final entry in items) _timelineEntryKey(entry): entry,
          };
          _selectedIds = _selectedIds
              .where(_visibleEntriesById.containsKey)
              .toSet();
          if (_selectedIds.isEmpty && _isSelectionMode) {
            _isSelectionMode = false;
          }
          final itemIndexByKey = <String, int>{
            for (var index = 0; index < items.length; index++)
              _timelineEntryKey(items[index]): index,
          };

          return RefreshIndicator(
            onRefresh: () async {
              if (_isSelectionMode) {
                return;
              }
              await ref
                  .read(timelineControllerProvider.notifier)
                  .refreshSelected();
            },
            child: LayoutBuilder(
              builder: (context, constraints) {
                final availableWidth = constraints.maxWidth.isFinite
                    ? constraints.maxWidth
                    : MediaQuery.sizeOf(context).width;
                final widthLimitedExtent = (availableWidth - 32)
                    .clamp(_minGridItemExtent, _maxGridItemExtent)
                    .toDouble();
                final maxExtent = _gridItemExtent
                    .clamp(_minGridItemExtent, widthLimitedExtent)
                    .toDouble();

                return Listener(
                  onPointerMove: (event) =>
                      _handleDragSelectionAt(event.position),
                  onPointerUp: (_) => _finishDragSelection(),
                  onPointerCancel: (_) => _finishDragSelection(),
                  child: CustomScrollView(
                    key: _gridAreaKey,
                    physics: _isSelectionMode
                        ? const ClampingScrollPhysics()
                        : const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      SliverToBoxAdapter(
                        child: _FeedModeHeader(
                          selectedMode: selectedMode,
                          onModeSelected: (mode) {
                            _clearSelection();
                            ref
                                .read(timelineControllerProvider.notifier)
                                .selectMode(mode);
                          },
                          onRefresh: () {
                            ref
                                .read(timelineControllerProvider.notifier)
                                .refreshSelected();
                          },
                          isRefreshing: feed.isRefreshing,
                        ),
                      ),
                      if (feed.isRefreshing)
                        const SliverToBoxAdapter(
                          child: LinearProgressIndicator(minHeight: 2),
                        ),
                      if ((feed.errorMessage ?? '').isNotEmpty && items.isEmpty)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                            child: _FeedErrorCard(
                              message: feed.errorMessage!,
                              onRetry: () {
                                ref
                                    .read(timelineControllerProvider.notifier)
                                    .refreshSelected();
                              },
                            ),
                          ),
                        ),
                      if (!feed.hasFetched && selectedMode == FeedMode.timeline)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: _TimelineNotFetchedView(
                            onRefresh: () {
                              ref
                                  .read(timelineControllerProvider.notifier)
                                  .refreshMode(FeedMode.timeline);
                            },
                          ),
                        )
                      else if (feed.hasFetched && items.isEmpty)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: _ModeEmptyView(mode: selectedMode),
                        )
                      else
                        SliverPadding(
                          padding: const EdgeInsets.all(16),
                          sliver: SliverGrid(
                            gridDelegate:
                                SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: maxExtent,
                                  crossAxisSpacing: 12,
                                  mainAxisSpacing: 12,
                                  childAspectRatio: 0.56,
                                ),
                            delegate: SliverChildBuilderDelegate(
                              (context, index) {
                                final entry = items[index];
                                final entryId = _timelineEntryKey(entry);
                                return GestureDetector(
                                  key: ValueKey(entryId),
                                  behavior: HitTestBehavior.opaque,
                                  onTap: _isSelectionMode
                                      ? () => _toggleSelection(entryId)
                                      : null,
                                  onLongPressStart: (_) {
                                    _enterSelectionMode(entryId);
                                  },
                                  onLongPressMoveUpdate: (details) {
                                    _handleDragSelectionAt(
                                      details.globalPosition,
                                    );
                                  },
                                  onLongPressEnd: (_) {
                                    _finishDragSelection();
                                  },
                                  child: KeyedSubtree(
                                    key: _tileKeyFor(entryId),
                                    child: PostMediaCard(
                                      post: entry.post,
                                      image: entry.image,
                                      onPreview: _isSelectionMode
                                          ? () => _toggleSelection(entryId)
                                          : () => _showImagePreview(entry),
                                      isSaved: savedMediaKeys.contains(
                                        entry.image.mediaKey,
                                      ),
                                      isSelected: _selectedIds.contains(
                                        entryId,
                                      ),
                                      onSave: _isSelectionMode
                                          ? () => _toggleSelection(entryId)
                                          : () => _saveImage(entry),
                                      onOpenPost: _isSelectionMode
                                          ? () => _toggleSelection(entryId)
                                          : () => _openPost(entry.post),
                                    ),
                                  ),
                                );
                              },
                              childCount: items.length,
                              findChildIndexCallback: (key) {
                                if (key is! ValueKey<String>) {
                                  return null;
                                }
                                return itemIndexByKey[key.value];
                              },
                            ),
                          ),
                        ),
                      if (feed.hasFetched && items.isNotEmpty)
                        SliverToBoxAdapter(
                          child: _TimelineFooter(
                            isLoadingMore: feed.isLoadingMore,
                            hasMore: feed.hasMore,
                            loadingLabel: selectedMode == FeedMode.reposted
                                ? 'Loading more and skipping non-image reposts if needed...'
                                : 'Loading more...',
                            errorMessage: items.isNotEmpty
                                ? feed.errorMessage
                                : null,
                            onLoadMore: () {
                              ref
                                  .read(timelineControllerProvider.notifier)
                                  .loadNextPage();
                            },
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class TimelineEntry {
  const TimelineEntry({required this.post, required this.image});

  final MediaPost post;
  final PostImage image;
}

class _BatchSaveProgress {
  const _BatchSaveProgress({
    required this.current,
    required this.total,
    required this.successCount,
    required this.failureCount,
    required this.inProgress,
  });

  const _BatchSaveProgress.idle()
    : current = 0,
      total = 0,
      successCount = 0,
      failureCount = 0,
      inProgress = false;

  final int current;
  final int total;
  final int successCount;
  final int failureCount;
  final bool inProgress;
}

class _FeedModeHeader extends StatelessWidget {
  const _FeedModeHeader({
    required this.selectedMode,
    required this.onModeSelected,
    required this.onRefresh,
    required this.isRefreshing,
  });

  final FeedMode selectedMode;
  final ValueChanged<FeedMode> onModeSelected;
  final VoidCallback onRefresh;
  final bool isRefreshing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<FeedMode>(
            segments: const [
              ButtonSegment<FeedMode>(
                value: FeedMode.reposted,
                label: Text('Reposts'),
                icon: Icon(Icons.repeat_rounded),
              ),
              ButtonSegment<FeedMode>(
                value: FeedMode.timeline,
                label: Text('Timeline'),
                icon: Icon(Icons.dynamic_feed_rounded),
              ),
            ],
            selected: {selectedMode},
            onSelectionChanged: (selection) {
              if (selection.isEmpty) {
                return;
              }
              onModeSelected(selection.first);
            },
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  _descriptionForMode(selectedMode),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: isRefreshing ? null : onRefresh,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(
                  selectedMode == FeedMode.timeline ? 'Update' : 'Refresh',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _descriptionForMode(FeedMode mode) {
    switch (mode) {
      case FeedMode.reposted:
        return 'Shows image posts you reposted. Cached results stay visible until you refresh manually.';
      case FeedMode.timeline:
        return 'Timeline mode never fetches on mode switch. It only calls the API when you update manually.';
      case FeedMode.liked:
        return 'Reserved for a future liked images mode.';
    }
  }
}

class _TimelineNotFetchedView extends StatelessWidget {
  const _TimelineNotFetchedView({required this.onRefresh});

  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.touch_app_rounded, size: 40),
            const SizedBox(height: 16),
            const Text(
              'Timeline mode only fetches when you update manually.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Switching to this mode does not call the X API. Tap Update when you want to load timeline images.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Update timeline'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeEmptyView extends StatelessWidget {
  const _ModeEmptyView({required this.mode});

  final FeedMode mode;

  @override
  Widget build(BuildContext context) {
    switch (mode) {
      case FeedMode.reposted:
        return const SectionEmptyView(
          title: 'No reposted image posts',
          message: 'You have not reposted any image posts yet.',
        );
      case FeedMode.timeline:
        return const SectionEmptyView(
          title: 'No image posts found',
          message: 'No image posts were found in the timeline.',
        );
      case FeedMode.liked:
        return const SizedBox.shrink();
    }
  }
}

class _FeedErrorCard extends StatelessWidget {
  const _FeedErrorCard({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message),
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

List<TimelineEntry> _flattenPosts(List<MediaPost> posts) {
  return posts
      .expand(
        (post) =>
            post.images.map((image) => TimelineEntry(post: post, image: image)),
      )
      .toList(growable: false);
}

String _timelineEntryKey(TimelineEntry entry) {
  return '${entry.post.sourceType.name}:${entry.post.postId}:${entry.image.mediaKey}';
}

class _TimelineFooter extends StatelessWidget {
  const _TimelineFooter({
    required this.isLoadingMore,
    required this.hasMore,
    required this.loadingLabel,
    required this.errorMessage,
    required this.onLoadMore,
  });

  final bool isLoadingMore;
  final bool hasMore;
  final String loadingLabel;
  final String? errorMessage;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    if (isLoadingMore) {
      return Padding(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Center(
          child: Column(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 12),
              Text(loadingLabel, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }

    if ((errorMessage ?? '').isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Center(
          child: Column(
            children: [
              Text(errorMessage!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: onLoadMore,
                child: const Text('Retry load more'),
              ),
            ],
          ),
        ),
      );
    }

    if (!hasMore) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Center(child: Text('No more posts')),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Center(
        child: FilledButton.tonal(
          onPressed: onLoadMore,
          child: const Text('Load more'),
        ),
      ),
    );
  }
}
