// ignore_for_file: deprecated_member_use

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/constants/app_routes.dart';
import '../../../../core/constants/storage_keys.dart';
import '../../../../domain/models/saved_media_record.dart';
import '../../../settings/presentation/providers/app_preferences_controller.dart';
import '../../../settings/presentation/widgets/app_preferences_dialog.dart';
import '../../../../widgets/async_value_view.dart';
import '../../../../widgets/section_empty_view.dart';
import '../providers/saved_media_controller.dart';
import '../widgets/creator_lookup_refresh.dart';
import '../widgets/creator_site_badges.dart';
import '../widgets/saved_media_filter_bar.dart';

class SavedMediaScreen extends ConsumerStatefulWidget {
  const SavedMediaScreen({super.key});

  @override
  ConsumerState<SavedMediaScreen> createState() => _SavedMediaScreenState();
}

class _SavedMediaScreenState extends ConsumerState<SavedMediaScreen> {
  static const int _defaultPreferredColumnCount = 2;
  static const int _maxPreferredColumnCount = 5;
  static const double _minTileWidth = 120;
  static const double _gridSpacing = 8;
  static const double _gridHorizontalPadding = 32;

  late final TextEditingController _tagQueryController;
  int _preferredColumnCount = _defaultPreferredColumnCount;

  @override
  void initState() {
    super.initState();
    _tagQueryController = TextEditingController();
    _loadPreferredColumnCount();
  }

  @override
  void dispose() {
    _tagQueryController.dispose();
    super.dispose();
  }

  Future<void> _showAppPreferencesDialog() async {
    await showDialog<void>(
      context: context,
      builder: (context) => const AppPreferencesDialog(),
    );
  }

  Future<void> _loadPreferredColumnCount() async {
    final prefs = await SharedPreferences.getInstance();
    final storedValue =
        prefs.getInt(StorageKeys.savedMediaPreferredColumnCount) ??
            _defaultPreferredColumnCount;
    if (!mounted) {
      return;
    }
    setState(() {
      _preferredColumnCount =
          storedValue.clamp(1, _maxPreferredColumnCount).toInt();
    });
  }

  Future<void> _savePreferredColumnCount(int value) async {
    final normalized = value.clamp(1, _maxPreferredColumnCount).toInt();
    if (mounted) {
      setState(() {
        _preferredColumnCount = normalized;
      });
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      StorageKeys.savedMediaPreferredColumnCount,
      normalized,
    );
  }

  int _computeEffectiveColumnCount(double width) {
    final availableWidth = (width - _gridHorizontalPadding).clamp(
      _minTileWidth,
      double.infinity,
    );
    final maxColumnsByWidth =
        ((availableWidth + _gridSpacing) / (_minTileWidth + _gridSpacing))
            .floor()
            .clamp(1, _maxPreferredColumnCount);
    return _preferredColumnCount < maxColumnsByWidth
        ? _preferredColumnCount
        : maxColumnsByWidth;
  }

  @override
  Widget build(BuildContext context) {
    final savedState = ref.watch(savedMediaControllerProvider);
    final savedItemsLabel = ref.watch(
      appPreferencesProvider.select((value) => value.savedItemsLabel),
    );
    final filter = ref.watch(savedMediaFilterProvider);
    final authors = ref.watch(savedMediaAuthorsProvider);
    final tags = ref.watch(savedMediaTagsProvider);
    final filteredRecords = ref.watch(savedMediaFilteredRecordsProvider);

    if (_tagQueryController.text != filter.tagQuery) {
      _tagQueryController.value = TextEditingValue(
        text: filter.tagQuery,
        selection: TextSelection.collapsed(offset: filter.tagQuery.length),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(savedItemsLabel),
        leading: IconButton(
          onPressed: () => context.go(AppRoutes.timeline),
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: 'Back to timeline',
        ),
        actions: [
          IconButton(
            onPressed: () => refreshCreatorLookups(
              context: context,
              ref: ref,
              records: filteredRecords,
            ),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Search visible creators',
          ),
          PopupMenuButton<int>(
            tooltip: 'Columns',
            initialValue: _preferredColumnCount,
            onSelected: _savePreferredColumnCount,
            itemBuilder: (context) {
              return List<PopupMenuEntry<int>>.generate(
                _maxPreferredColumnCount,
                (index) {
                  final value = index + 1;
                  return PopupMenuItem<int>(
                    value: value,
                    child: Row(
                      children: [
                        Icon(
                          Icons.grid_view_rounded,
                          size: 18,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 10),
                        Text('$value column${value == 1 ? '' : 's'}'),
                      ],
                    ),
                  );
                },
              );
            },
            icon: const Icon(Icons.grid_view_rounded),
          ),
          IconButton(
            onPressed: () async {
              try {
                await ref
                    .read(savedMediaControllerProvider.notifier)
                    .openGalleryApp();
              } catch (error) {
                if (context.mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text(error.toString())));
                }
              }
            },
            icon: const Icon(Icons.photo_library_outlined),
            tooltip: 'Open gallery app',
          ),
          IconButton(
            onPressed: _showAppPreferencesDialog,
            icon: const Icon(Icons.tune_rounded),
            tooltip: 'Display settings',
          ),
        ],
      ),
      body: Column(
        children: [
          FutureBuilder<String>(
            future: ref
                .read(savedMediaControllerProvider.notifier)
                .getStorageDirectory(),
            builder: (context, snapshot) {
              return Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Text(
                  'Storage: ${snapshot.data ?? 'Checking...'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              );
            },
          ),
          SavedMediaFilterBar(
            filter: filter,
            authors: authors,
            suggestedTags: tags,
            tagQueryController: _tagQueryController,
            onSelectAuthor: (value) {
              ref.read(savedMediaFilterProvider.notifier).setAuthor(value);
            },
            onToggleFavoritesOnly: () {
              ref.read(savedMediaFilterProvider.notifier).toggleFavoritesOnly();
            },
            onTagQueryChanged: (value) {
              ref.read(savedMediaFilterProvider.notifier).setTagQuery(value);
            },
            onClearFilters: () {
              ref.read(savedMediaFilterProvider.notifier).clear();
            },
          ),
          Expanded(
            child: AsyncValueView(
              value: savedState,
              onRetry: () => ref.invalidate(savedMediaControllerProvider),
              data: (records) {
                if (records.isEmpty) {
                  return SectionEmptyView(
                    title: 'No $savedItemsLabel yet',
                    message: 'Save an image from the timeline screen first.',
                  );
                }

                if (filteredRecords.isEmpty) {
                  return const SectionEmptyView(
                    title: 'No matching items',
                    message: 'Try clearing the author, favorites, or tag filters.',
                  );
                }

                return LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth.isFinite
                        ? constraints.maxWidth
                        : MediaQuery.sizeOf(context).width;
                    final effectiveColumnCount =
                        _computeEffectiveColumnCount(width);
                    final compactMode = effectiveColumnCount >= 4;
                    final authorGroups = _buildAuthorGroups(filteredRecords);
                    final childAspectRatio = effectiveColumnCount <= 1
                        ? 1.45
                        : effectiveColumnCount == 2
                            ? 0.92
                            : 0.82;

                    return GridView.builder(
                      padding: const EdgeInsets.all(16),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: effectiveColumnCount,
                        crossAxisSpacing: _gridSpacing,
                        mainAxisSpacing: _gridSpacing,
                        childAspectRatio: childAspectRatio,
                      ),
                      itemCount: authorGroups.length,
                      itemBuilder: (context, index) {
                        final group = authorGroups[index];
                        return _AuthorGroupCard(
                          group: group,
                          compactMode: compactMode,
                          onOpen: () => context.push(
                            AppRoutes.savedAuthorPath(group.authorUsername),
                          ),
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  List<_AuthorGroup> _buildAuthorGroups(List<SavedMediaRecord> records) {
    final grouped = <String, List<SavedMediaRecord>>{};
    for (final record in records) {
      grouped.putIfAbsent(record.authorUsername, () => []).add(record);
    }

    final groups = grouped.entries.map((entry) {
      final records = entry.value
        ..sort((a, b) => b.savedAt.compareTo(a.savedAt));
      return _AuthorGroup(
        authorUsername: entry.key,
        records: records,
      );
    }).toList(growable: false)
      ..sort((a, b) => b.latestSavedAt.compareTo(a.latestSavedAt));

    return groups;
  }
}

class _AuthorGroup {
  const _AuthorGroup({
    required this.authorUsername,
    required this.records,
  });

  final String authorUsername;
  final List<SavedMediaRecord> records;

  SavedMediaRecord get coverRecord => records.first;

  DateTime get latestSavedAt => coverRecord.savedAt;
}

class _AuthorGroupCard extends StatelessWidget {
  const _AuthorGroupCard({
    required this.group,
    required this.compactMode,
    required this.onOpen,
  });

  final _AuthorGroup group;
  final bool compactMode;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final record = group.coverRecord;
    final previewFile = File(record.previewFilePath);
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      previewFile.existsSync()
                          ? Image.file(previewFile, fit: BoxFit.cover)
                          : const ColoredBox(
                              color: Color(0xFFE5E7EB),
                              child: Icon(Icons.image_not_supported_outlined),
                            ),
                      Positioned(
                        right: 8,
                        bottom: 8,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.58),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 5,
                            ),
                            child: Text(
                              '${group.records.length}',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: compactMode ? 8 : 12),
              Text(
                record.authorName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: compactMode
                    ? theme.textTheme.titleSmall
                    : theme.textTheme.titleMedium,
              ),
              Text(
                '@${group.authorUsername}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
              CreatorSiteBadges(record: record, compact: compactMode),
            ],
          ),
        ),
      ),
    );
  }
}
