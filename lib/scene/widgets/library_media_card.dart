import 'package:flutter/material.dart';

/// Shared card layout for the library, with actions outside the cover image.
class LibraryMediaCard extends StatelessWidget {
  const LibraryMediaCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.preview,
    this.listView = false,
    this.selected = false,
    this.isFavorite = false,
    this.onToggleFavorite,
    this.menu,
  });
  final String title;
  final String subtitle;
  final Widget preview;
  final bool listView;
  final bool selected;
  final bool isFavorite;
  final VoidCallback? onToggleFavorite;
  final Widget? menu;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final titleWidget = Text(
      title,
      maxLines: listView ? 2 : 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.bodyMedium,
    );
    final metadata = Text(
      subtitle,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(
        context,
      ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
    );
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (onToggleFavorite != null)
          IconButton(
            tooltip: isFavorite ? 'お気に入りを解除' : 'お気に入りに追加',
            icon: Icon(
              isFavorite ? Icons.star_rounded : Icons.star_outline_rounded,
            ),
            color: isFavorite ? scheme.primary : scheme.onSurfaceVariant,
            onPressed: onToggleFavorite,
          ),
        if (menu != null) menu!,
      ],
    );
    return Semantics(
      selected: selected,
      child: AnimatedContainer(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: selected
              ? scheme.primaryContainer
              : scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: listView
            ? Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    SizedBox(width: 64, height: 80, child: preview),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          titleWidget,
                          const SizedBox(height: 4),
                          metadata,
                        ],
                      ),
                    ),
                    if (selected)
                      Icon(Icons.check_circle, color: scheme.primary),
                    actions,
                  ],
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        preview,
                        if (selected)
                          Positioned(
                            top: 8,
                            left: 8,
                            child: Icon(
                              Icons.check_circle,
                              color: scheme.primary,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: titleWidget,
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Row(
                      children: [
                        Expanded(child: metadata),
                        actions,
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
