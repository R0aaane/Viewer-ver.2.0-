import 'package:flutter/material.dart';
import '../../models/mediaItem.dart';
import '../../models/tag.dart';
import '../../models/tag_with_id.dart';
import '../../services/item_name_service.dart';
import '../../widgets/gallery_tag_picker.dart';
import 'inspector_pane.dart';

/// Reads tags only for the inspected item. Presentation never alters tag meaning.
class LibraryInspector extends StatefulWidget {
  const LibraryInspector({
    super.key,
    required this.item,
    required this.folderLabel,
    required this.preview,
    required this.loadTags,
    required this.onOpen,
    required this.onEditTags,
    required this.onClose,
  });
  final MediaItem item;
  final String folderLabel;
  final Widget preview;
  final Future<List<TagWithId>> Function() loadTags;
  final Future<void> Function() onOpen;
  final Future<void> Function() onEditTags;
  final VoidCallback onClose;

  @override
  State<LibraryInspector> createState() => _LibraryInspectorState();
}

class _LibraryInspectorState extends State<LibraryInspector> {
  late Future<List<TagWithId>> _tags;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _tags = widget.loadTags();
  }

  @override
  void didUpdateWidget(covariant LibraryInspector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id) _tags = widget.loadTags();
  }

  Future<void> _runAndReload(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) {
        setState(() {
          _tags = widget.loadTags();
        });
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('タグの更新を確認できませんでした。再度お試しください。')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final theme = Theme.of(context);
    return InspectorPane(
      title: '詳細',
      onClose: widget.onClose,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(height: 180, child: widget.preview),
          ),
          const SizedBox(height: 20),
          SelectableText(
            ItemNameService.formatMediaTitle(item.displayName, kind: item.kind),
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            ItemNameService.kindLabel(item),
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : () => _runAndReload(widget.onOpen),
            icon: const Icon(Icons.open_in_new),
            label: const Text('開く'),
          ),
          const SizedBox(height: 24),
          Text('ファイル情報', style: theme.textTheme.titleSmall),
          const SizedBox(height: 12),
          _Metadata(label: 'フォルダ', value: widget.folderLabel),
          if (item.sizeBytes != null)
            _Metadata(label: 'サイズ', value: _formatSize(item.sizeBytes!)),
          if (item.modified != null)
            _Metadata(label: '更新日', value: _date(item.modified!)),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(child: Text('タグ', style: theme.textTheme.titleSmall)),
              TextButton.icon(
                onPressed: _busy
                    ? null
                    : () => _runAndReload(widget.onEditTags),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('追加'),
              ),
            ],
          ),
          if (_busy) const LinearProgressIndicator(),
          FutureBuilder<List<TagWithId>>(
            future: _tags,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const LinearProgressIndicator();
              }
              if (snapshot.hasError) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('タグを読み込めませんでした。'),
                    TextButton(
                      onPressed: () => setState(() {
                        _tags = widget.loadTags();
                      }),
                      child: const Text('再試行'),
                    ),
                  ],
                );
              }
              final tags = snapshot.data ?? const [];
              if (tags.isEmpty) return const Text('タグはまだ付いていません。');
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final category in TagCategory.values)
                    if (tags.any(
                      (entry) => entry.tag.category == category,
                    )) ...[
                      const SizedBox(height: 12),
                      Text(
                        galleryTagCategoryLabels[category]!,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final entry in tags.where(
                            (entry) => entry.tag.category == category,
                          ))
                            Chip(label: Text(entry.tag.name)),
                        ],
                      ),
                    ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  String _date(DateTime value) {
    final local = value.toLocal();
    return '${local.year}/${local.month.toString().padLeft(2, '0')}/${local.day.toString().padLeft(2, '0')}';
  }

  String _formatSize(int bytes) => bytes < 1024
      ? '$bytes B'
      : bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(1)} KB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

class _Metadata extends StatelessWidget {
  const _Metadata({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        SelectableText(value),
      ],
    ),
  );
}
