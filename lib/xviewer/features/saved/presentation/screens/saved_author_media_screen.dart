import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/app_routes.dart';
import '../../../../domain/models/saved_media_record.dart';
import '../../../../services/service_providers.dart';
import '../../../../widgets/async_value_view.dart';
import '../../../../widgets/section_empty_view.dart';
import '../models/saved_media_viewer_context.dart';
import '../providers/saved_media_controller.dart';
import '../widgets/creator_lookup_refresh.dart';
import '../widgets/creator_search_sheet.dart';
import '../widgets/saved_media_card.dart';

class SavedAuthorMediaScreen extends ConsumerWidget {
  const SavedAuthorMediaScreen({
    super.key,
    required this.authorUsername,
  });

  final String authorUsername;

  static const int _maxColumnCount = 5;
  static const double _minTileWidth = 120;
  static const double _gridSpacing = 8;
  static const double _gridHorizontalPadding = 32;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final savedState = ref.watch(savedMediaControllerProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text('@$authorUsername'),
        leading: IconButton(
          onPressed: () => context.go(AppRoutes.saved),
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: 'Back to saved authors',
        ),
        actions: [
          IconButton(
            onPressed: () async {
              final records =
                  ref.read(savedMediaControllerProvider).valueOrNull ??
                      const <SavedMediaRecord>[];
              final authorRecords = records
                  .where((record) => record.authorUsername == authorUsername)
                  .toList(growable: false);
              await refreshCreatorLookups(
                context: context,
                ref: ref,
                records: authorRecords,
              );
            },
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Search this creator',
          ),
        ],
      ),
      body: AsyncValueView(
        value: savedState,
        onRetry: () => ref.invalidate(savedMediaControllerProvider),
        data: (records) {
          final authorRecords = records
              .where((record) => record.authorUsername == authorUsername)
              .toList(growable: false)
            ..sort((a, b) => b.savedAt.compareTo(a.savedAt));

          if (authorRecords.isEmpty) {
            return const SectionEmptyView(
              title: 'No saved items',
              message: 'This author has no saved images.',
            );
          }

          return LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth.isFinite
                  ? constraints.maxWidth
                  : MediaQuery.sizeOf(context).width;
              final columns = _computeColumnCount(width);
              final compactMode = columns >= 4;

              return GridView.builder(
                padding: const EdgeInsets.all(16),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: _gridSpacing,
                  mainAxisSpacing: _gridSpacing,
                  childAspectRatio: _computeChildAspectRatio(columns),
                ),
                itemCount: authorRecords.length,
                itemBuilder: (context, index) {
                  final record = authorRecords[index];
                  final viewerContext = SavedMediaViewerContext(
                    recordIds: authorRecords
                        .map((entry) => entry.recordId)
                        .toList(growable: false),
                    initialIndex: index,
                    sourceType: SavedMediaViewerSourceType.author,
                    sourceTitle: '@$authorUsername',
                  );
                  return SavedMediaCard(
                    record: record,
                    isGrid: columns > 1,
                    compactMode: compactMode,
                    onOpen: () => context.push(
                      AppRoutes.savedDetailPath(record.recordId),
                      extra: viewerContext,
                    ),
                    onToggleFavorite: () => ref
                        .read(savedMediaControllerProvider.notifier)
                        .toggleFavorite(record.recordId),
                    onOpenCreatorSearch: () => showCreatorSearchSheet(
                      context: context,
                      ref: ref,
                      authorName: record.authorName,
                      authorUsername: record.authorUsername,
                    ),
                    onOpenPost: () => _openPost(context, ref, record),
                    onDelete: () => _deleteRecord(context, ref, record),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  int _computeColumnCount(double width) {
    final availableWidth = (width - _gridHorizontalPadding).clamp(
      _minTileWidth,
      double.infinity,
    );
    return ((availableWidth + _gridSpacing) / (_minTileWidth + _gridSpacing))
        .floor()
        .clamp(1, _maxColumnCount);
  }

  double _computeChildAspectRatio(int columns) {
    if (columns <= 1) {
      return 1.18;
    }
    if (columns == 2) {
      return 0.84;
    }
    if (columns == 3) {
      return 0.78;
    }
    if (columns == 4) {
      return 0.72;
    }
    return 0.68;
  }

  Future<void> _openPost(
    BuildContext context,
    WidgetRef ref,
    SavedMediaRecord record,
  ) async {
    try {
      await ref.read(linkLauncherServiceProvider).openExternal(
            record.originalPostUrl,
          );
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> _deleteRecord(
    BuildContext context,
    WidgetRef ref,
    SavedMediaRecord record,
  ) async {
    await ref.read(savedMediaControllerProvider.notifier).deleteRecord(record);
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Saved record removed')));
    }
  }
}
