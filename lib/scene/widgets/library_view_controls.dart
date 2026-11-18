import 'package:flutter/material.dart';

/// Presentation preferences only; changing these never changes the result set.
class LibraryViewControls extends StatelessWidget {
  const LibraryViewControls({
    super.key,
    required this.listView,
    required this.largeCovers,
    required this.cropCovers,
    required this.onListViewChanged,
    required this.onLargeCoversChanged,
    required this.onCropCoversChanged,
  });

  final bool listView;
  final bool largeCovers;
  final bool cropCovers;
  final ValueChanged<bool> onListViewChanged;
  final ValueChanged<bool> onLargeCoversChanged;
  final ValueChanged<bool> onCropCoversChanged;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        tooltip: listView ? 'グリッド表示' : 'リスト表示',
        isSelected: listView,
        icon: const Icon(Icons.view_list_outlined),
        selectedIcon: const Icon(Icons.grid_view_outlined),
        onPressed: () => onListViewChanged(!listView),
      ),
      PopupMenuButton<String>(
        tooltip: '表示オプション',
        icon: const Icon(Icons.tune_outlined),
        onSelected: (value) {
          if (value == 'size') onLargeCoversChanged(!largeCovers);
          if (value == 'crop') onCropCoversChanged(!cropCovers);
        },
        itemBuilder: (_) => [
          CheckedPopupMenuItem(
            value: 'size',
            checked: largeCovers,
            child: const Text('大きなサムネイル'),
          ),
          CheckedPopupMenuItem(
            value: 'crop',
            checked: cropCovers,
            child: const Text('表紙を枠いっぱいに表示'),
          ),
        ],
      ),
    ],
  );
}

class LibraryQueryChips extends StatelessWidget {
  const LibraryQueryChips({
    super.key,
    required this.query,
    required this.onChanged,
    required this.onClearAll,
  });

  final String query;
  final ValueChanged<String> onChanged;
  final VoidCallback onClearAll;

  @override
  Widget build(BuildContext context) {
    // Match the existing search grammar, including repeated tokens.
    final tokens = query
        .trim()
        .split(RegExp(r'\s+'))
        .where((token) => token.isNotEmpty)
        .toList();
    return Row(
      children: [
        Expanded(
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: tokens.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (_, index) => InputChip(
              label: Text(tokens[index]),
              deleteButtonTooltipMessage: 'この検索条件を解除',
              onDeleted: () {
                final remaining = List<String>.of(tokens)..removeAt(index);
                onChanged(remaining.join(' '));
              },
            ),
          ),
        ),
        TextButton(onPressed: onClearAll, child: const Text('全解除')),
      ],
    );
  }
}
