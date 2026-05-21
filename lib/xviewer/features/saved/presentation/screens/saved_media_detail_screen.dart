// ignore_for_file: deprecated_member_use

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/utils/date_formatter.dart';
import '../../../../domain/models/save_location_type.dart';
import '../../../../domain/models/saved_media_record.dart';
import '../../../../services/service_providers.dart';
import '../../../../widgets/section_empty_view.dart';
import '../models/saved_media_viewer_context.dart';
import '../providers/saved_media_controller.dart';
import '../widgets/creator_search_sheet.dart';
import '../widgets/creator_site_badges.dart';

class SavedMediaDetailScreen extends ConsumerStatefulWidget {
  const SavedMediaDetailScreen({
    super.key,
    required this.recordId,
    this.viewerContext,
  });

  final String recordId;
  final SavedMediaViewerContext? viewerContext;

  @override
  ConsumerState<SavedMediaDetailScreen> createState() =>
      _SavedMediaDetailScreenState();
}

class _SavedMediaDetailScreenState
    extends ConsumerState<SavedMediaDetailScreen> {
  late final FocusNode _readerFocusNode;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _readerFocusNode = FocusNode(debugLabel: 'saved-media-reader');
    _currentIndex = widget.viewerContext?.initialIndex ?? 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _readerFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _readerFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final allRecords =
        ref.watch(savedMediaControllerProvider).valueOrNull ??
        const <SavedMediaRecord>[];
    final recordsById = {
      for (final record in allRecords) record.recordId: record,
    };
    final viewerRecordIds =
        widget.viewerContext?.recordIds ?? <String>[widget.recordId];
    final resolvedRecords = viewerRecordIds
        .map((id) => recordsById[id])
        .whereType<SavedMediaRecord>()
        .toList(growable: false);
    final fallbackRecord = ref.watch(savedMediaRecordProvider(widget.recordId));
    final recordList = resolvedRecords.isNotEmpty
        ? resolvedRecords
        : (fallbackRecord == null
              ? const <SavedMediaRecord>[]
              : [fallbackRecord]);
    final safeIndex = recordList.isEmpty
        ? 0
        : _currentIndex.clamp(0, recordList.length - 1);
    final record = recordList.isEmpty ? null : recordList[safeIndex];

    if (record == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const SectionEmptyView(
          title: 'Saved item not found',
          message: 'The record may have been deleted.',
        ),
      );
    }

    final hasPrev = safeIndex > 0;
    final hasNext = safeIndex < recordList.length - 1;
    final previewFile = File(record.previewFilePath);
    final sourceTitle = widget.viewerContext?.sourceTitle ?? '';

    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.arrowLeft):
            const _NavigatePreviousIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowRight):
            const _NavigateNextIntent(),
        const SingleActivator(LogicalKeyboardKey.escape): const DismissIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _NavigatePreviousIntent: CallbackAction<_NavigatePreviousIntent>(
            onInvoke: (_) {
              if (_shouldHandleKeyboardNavigation()) {
                _prev(recordList);
              }
              return null;
            },
          ),
          _NavigateNextIntent: CallbackAction<_NavigateNextIntent>(
            onInvoke: (_) {
              if (_shouldHandleKeyboardNavigation()) {
                _next(recordList);
              }
              return null;
            },
          ),
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              if (Navigator.of(context).canPop()) {
                Navigator.of(context).maybePop();
              }
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          focusNode: _readerFocusNode,
          child: Scaffold(
            appBar: AppBar(
              title: Text('@${record.authorUsername}'),
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(26),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '${safeIndex + 1} / ${recordList.length}${sourceTitle.isNotEmpty ? '  •  $sourceTitle' : ''}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
              actions: [
                IconButton(
                  onPressed: () => ref
                      .read(savedMediaControllerProvider.notifier)
                      .toggleFavorite(record.recordId),
                  icon: Icon(
                    record.favorite ? Icons.favorite : Icons.favorite_border,
                  ),
                  tooltip: 'Toggle favorite',
                ),
              ],
            ),
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 920),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildReader(
                        context: context,
                        previewFile: previewFile,
                        imageUrl: record.imageUrl,
                        hasPrev: hasPrev,
                        hasNext: hasNext,
                        onPrev: () => _prev(recordList),
                        onNext: () => _next(recordList),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _CreatorNameButton(
                                  name: record.authorName,
                                  onPressed: () => showCreatorSearchSheet(
                                    context: context,
                                    ref: ref,
                                    authorName: record.authorName,
                                    authorUsername: record.authorUsername,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '@${record.authorUsername}',
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                                CreatorSiteBadges(
                                  record: record,
                                  allowNetworkLookup: true,
                                ),
                              ],
                            ),
                          ),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              FilledButton.tonalIcon(
                                onPressed: () => _openPost(
                                  context,
                                  ref,
                                  record.originalPostUrl,
                                ),
                                icon: const Icon(Icons.open_in_new_rounded),
                                label: const Text('Open post'),
                              ),
                              if (record.saveLocationType ==
                                  SaveLocationType.gallery)
                                FilledButton.tonalIcon(
                                  onPressed: () => _openGallery(context, ref),
                                  icon: const Icon(
                                    Icons.photo_library_outlined,
                                  ),
                                  label: const Text('Gallery'),
                                ),
                            ],
                          ),
                        ],
                      ),
                      if (record.text.trim().isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Text(
                          record.text,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                      ],
                      const SizedBox(height: 20),
                      _SectionCard(
                        title: 'Tags',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                ...record.tags.map((tag) {
                                  return InputChip(
                                    label: Text('#$tag'),
                                    onDeleted: () => ref
                                        .read(
                                          savedMediaControllerProvider.notifier,
                                        )
                                        .removeTag(
                                          recordId: record.recordId,
                                          tag: tag,
                                        ),
                                  );
                                }),
                                ActionChip(
                                  onPressed: () => _showAddTagDialog(
                                    context,
                                    ref,
                                    record.recordId,
                                  ),
                                  avatar: const Icon(Icons.add_rounded),
                                  label: const Text('Add tag'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      _SectionCard(
                        title: 'Saved info',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _InfoRow(
                              label: 'Saved at',
                              value: DateFormatter.shortDateTime(
                                record.savedAt,
                              ),
                            ),
                            _InfoRow(
                              label: 'Post time',
                              value: DateFormatter.shortDateTime(
                                record.createdAt,
                              ),
                            ),
                            _InfoRow(
                              label: 'Favorite',
                              value: record.favorite ? 'Yes' : 'No',
                            ),
                            _InfoRow(
                              label: 'Save location',
                              value: _saveLocationLabel(
                                record.saveLocationType,
                              ),
                            ),
                            _InfoRow(
                              label: 'Saved path',
                              value: record.localSavedPath,
                            ),
                            _InfoRow(
                              label: 'Preview path',
                              value: record.previewFilePath,
                            ),
                            _InfoRow(
                              label: 'Image URL',
                              value: record.imageUrl,
                            ),
                            _InfoRow(
                              label: 'Source URL',
                              value: record.sourceImageUrl,
                            ),
                            if ((record.galleryContentUri ?? '').isNotEmpty)
                              _InfoRow(
                                label: 'Gallery URI',
                                value: record.galleryContentUri!,
                              ),
                            if ((record.galleryDisplayName ?? '').isNotEmpty)
                              _InfoRow(
                                label: 'Gallery name',
                                value: record.galleryDisplayName!,
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReader({
    required BuildContext context,
    required File previewFile,
    required String imageUrl,
    required bool hasPrev,
    required bool hasNext,
    required VoidCallback onPrev,
    required VoidCallback onNext,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: AspectRatio(
        aspectRatio: 1,
        child: Stack(
          children: [
            Positioned.fill(
              child: previewFile.existsSync()
                  ? Image.file(previewFile, fit: BoxFit.contain)
                  : imageUrl.startsWith('http')
                  ? Image.network(imageUrl, fit: BoxFit.contain)
                  : const ColoredBox(
                      color: Color(0xFFE5E7EB),
                      child: Icon(Icons.image_not_supported_outlined),
                    ),
            ),
            Positioned(
              left: 12,
              top: 0,
              bottom: 0,
              child: _ReaderNavigationButton(
                icon: Icons.chevron_left_rounded,
                tooltip: 'Previous',
                enabled: hasPrev,
                onPressed: onPrev,
              ),
            ),
            Positioned(
              right: 12,
              top: 0,
              bottom: 0,
              child: _ReaderNavigationButton(
                icon: Icons.chevron_right_rounded,
                tooltip: 'Next',
                enabled: hasNext,
                onPressed: onNext,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _prev(List<SavedMediaRecord> records) {
    if (_currentIndex <= 0 || records.isEmpty) {
      return;
    }

    setState(() {
      _currentIndex -= 1;
    });
  }

  void _next(List<SavedMediaRecord> records) {
    if (records.isEmpty || _currentIndex >= records.length - 1) {
      return;
    }

    setState(() {
      _currentIndex += 1;
    });
  }

  bool _shouldHandleKeyboardNavigation() {
    if (!_readerFocusNode.hasFocus) {
      return false;
    }

    final focusedContext = FocusManager.instance.primaryFocus?.context;
    final focusedWidget = focusedContext?.widget;
    return focusedWidget is! EditableText;
  }

  Future<void> _showAddTagDialog(
    BuildContext context,
    WidgetRef ref,
    String recordId,
  ) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Add tag'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'example',
              prefixText: '#',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('Add'),
            ),
          ],
        );
      },
    );
    controller.dispose();

    if (value == null || value.trim().isEmpty) {
      return;
    }

    await ref
        .read(savedMediaControllerProvider.notifier)
        .addTag(recordId: recordId, rawTag: value);

    if (mounted) {
      _readerFocusNode.requestFocus();
    }
  }

  Future<void> _openPost(
    BuildContext context,
    WidgetRef ref,
    String url,
  ) async {
    try {
      await ref.read(linkLauncherServiceProvider).openExternal(url);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> _openGallery(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(savedMediaControllerProvider.notifier).openGalleryApp();
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  String _saveLocationLabel(SaveLocationType type) {
    return switch (type) {
      SaveLocationType.gallery => 'Gallery',
      SaveLocationType.remoteHost => 'Host Saved_images',
      SaveLocationType.appPrivate => 'App storage',
    };
  }
}

class _NavigatePreviousIntent extends Intent {
  const _NavigatePreviousIntent();
}

class _NavigateNextIntent extends Intent {
  const _NavigateNextIntent();
}

class _CreatorNameButton extends StatelessWidget {
  const _CreatorNameButton({required this.name, required this.onPressed});

  final String name;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'Search creator',
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(
            name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: colorScheme.primary,
              decoration: TextDecoration.underline,
              decorationColor: colorScheme.primary,
            ),
          ),
        ),
      ),
    );
  }
}

class _ReaderNavigationButton extends StatelessWidget {
  const _ReaderNavigationButton({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.35),
          shape: BoxShape.circle,
        ),
        child: IconButton(
          onPressed: enabled ? onPressed : null,
          icon: Icon(icon, size: 28),
          tooltip: tooltip,
          color: Colors.white,
          disabledColor: Colors.white38,
          constraints: const BoxConstraints.tightFor(width: 48, height: 48),
          style: IconButton.styleFrom(
            backgroundColor: Colors.transparent,
            shape: const CircleBorder(),
          ),
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 2),
          SelectableText(value),
        ],
      ),
    );
  }
}
