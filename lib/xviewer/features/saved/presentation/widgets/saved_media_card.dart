import 'dart:io';

import 'package:flutter/material.dart';

import '../../../../core/utils/date_formatter.dart';
import '../../../../domain/models/save_location_type.dart';
import '../../../../domain/models/saved_media_record.dart';
import 'creator_site_badges.dart';

class SavedMediaCard extends StatelessWidget {
  const SavedMediaCard({
    super.key,
    required this.record,
    required this.isGrid,
    this.compactMode = false,
    required this.onOpen,
    required this.onToggleFavorite,
    required this.onOpenCreatorSearch,
    required this.onOpenPost,
    required this.onDelete,
  });

  final SavedMediaRecord record;
  final bool isGrid;
  final bool compactMode;
  final VoidCallback onOpen;
  final VoidCallback onToggleFavorite;
  final VoidCallback onOpenCreatorSearch;
  final VoidCallback onOpenPost;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final previewFile = File(record.previewFilePath);
    final image = ClipRRect(
      borderRadius: BorderRadius.circular(isGrid ? 18 : 16),
      child: AspectRatio(
        aspectRatio: isGrid ? 1 : 1.15,
        child: previewFile.existsSync()
            ? Image.file(previewFile, fit: BoxFit.cover)
            : const ColoredBox(
                color: Color(0xFFE5E7EB),
                child: Icon(Icons.image_not_supported_outlined),
              ),
      ),
    );

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: isGrid
              ? _GridBody(
                  record: record,
                  image: image,
                  compactMode: compactMode,
                  onToggleFavorite: onToggleFavorite,
                  onOpenCreatorSearch: onOpenCreatorSearch,
                  onOpenPost: onOpenPost,
                )
              : _ListBody(
                  record: record,
                  image: image,
                  onToggleFavorite: onToggleFavorite,
                  onOpenCreatorSearch: onOpenCreatorSearch,
                  onOpenPost: onOpenPost,
                  onDelete: onDelete,
                ),
        ),
      ),
    );
  }
}

class _GridBody extends StatelessWidget {
  const _GridBody({
    required this.record,
    required this.image,
    required this.compactMode,
    required this.onToggleFavorite,
    required this.onOpenCreatorSearch,
    required this.onOpenPost,
  });

  final SavedMediaRecord record;
  final Widget image;
  final bool compactMode;
  final VoidCallback onToggleFavorite;
  final VoidCallback onOpenCreatorSearch;
  final VoidCallback onOpenPost;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(child: image),
              Positioned(
                top: 8,
                right: 8,
                child: IconButton.filledTonal(
                  visualDensity: compactMode
                      ? VisualDensity.compact
                      : VisualDensity.standard,
                  constraints: BoxConstraints.tightFor(
                    width: compactMode ? 34 : 40,
                    height: compactMode ? 34 : 40,
                  ),
                  onPressed: onToggleFavorite,
                  icon: Icon(
                    record.favorite ? Icons.favorite : Icons.favorite_border,
                    size: compactMode ? 18 : 20,
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: compactMode ? 8 : 12),
        _AuthorNameButton(
          name: record.authorName,
          onPressed: onOpenCreatorSearch,
          style: compactMode
              ? theme.textTheme.titleSmall
              : theme.textTheme.titleMedium,
        ),
        Text(
          '@${record.authorUsername}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall,
        ),
        CreatorSiteBadges(record: record, compact: compactMode),
        if (!compactMode) ...[
          const SizedBox(height: 8),
          Text(
            DateFormatter.shortDateTime(record.savedAt),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ],
        if (!compactMode && record.tags.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: record.tags.take(2).map((tag) {
              return Chip(
                label: Text(
                  '#$tag',
                  overflow: TextOverflow.ellipsis,
                ),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              );
            }).toList(growable: false),
          ),
        ],
        SizedBox(height: compactMode ? 4 : 8),
        Align(
          alignment: Alignment.centerRight,
          child: IconButton(
            visualDensity:
                compactMode ? VisualDensity.compact : VisualDensity.standard,
            constraints: BoxConstraints.tightFor(
              width: compactMode ? 32 : 40,
              height: compactMode ? 32 : 40,
            ),
            padding: EdgeInsets.zero,
            onPressed: onOpenPost,
            icon: Icon(
              Icons.open_in_new_rounded,
              size: compactMode ? 18 : 22,
            ),
            tooltip: 'Open post',
          ),
        ),
      ],
    );
  }
}

class _ListBody extends StatelessWidget {
  const _ListBody({
    required this.record,
    required this.image,
    required this.onToggleFavorite,
    required this.onOpenCreatorSearch,
    required this.onOpenPost,
    required this.onDelete,
  });

  final SavedMediaRecord record;
  final Widget image;
  final VoidCallback onToggleFavorite;
  final VoidCallback onOpenCreatorSearch;
  final VoidCallback onOpenPost;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 180, child: image),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _AuthorNameButton(
                          name: record.authorName,
                          onPressed: onOpenCreatorSearch,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 2),
                        Text('@${record.authorUsername}'),
                        CreatorSiteBadges(record: record),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: onToggleFavorite,
                    icon: Icon(
                      record.favorite ? Icons.favorite : Icons.favorite_border,
                    ),
                    tooltip: 'Toggle favorite',
                  ),
                ],
              ),
              if (record.text.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  record.text,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 8),
              Text(
                'Saved: ${DateFormatter.shortDateTime(record.savedAt)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              Text(
                record.saveLocationType == SaveLocationType.gallery
                    ? 'Location: Gallery'
                    : 'Location: App storage',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              Text(
                record.localSavedPath,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (record.tags.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: record.tags.map((tag) {
                    return Chip(
                      label: Text('#$tag'),
                      visualDensity: VisualDensity.compact,
                    );
                  }).toList(growable: false),
                ),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: onOpenPost,
                    icon: const Icon(Icons.open_in_new_rounded),
                    label: const Text('Open post'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: const Text('Delete'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AuthorNameButton extends StatelessWidget {
  const _AuthorNameButton({
    required this.name,
    required this.onPressed,
    required this.style,
  });

  final String name;
  final VoidCallback onPressed;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'Search creator',
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style?.copyWith(
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
