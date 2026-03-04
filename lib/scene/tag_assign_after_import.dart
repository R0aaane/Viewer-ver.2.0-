import 'package:flutter/material.dart';

import '../database/tag_service.dart';
import '../models/mediaItem.dart';
import '../models/tag.dart';

class TagAssignAfterImportPage extends StatefulWidget {
  final List<MediaItem> items;
  final TagService tagService;

  const TagAssignAfterImportPage({
    super.key,
    required this.items,
    required this.tagService,
  });

  @override
  State<TagAssignAfterImportPage> createState() =>
      _TagAssignAfterImportPageState();
}

class _TagAssignAfterImportPageState extends State<TagAssignAfterImportPage> {
  TagCategory _selectedCategory = TagCategory.artist;
  final TextEditingController _tagCtrl = TextEditingController();

  // 付与予定のタグ一覧（カテゴリ込み）
  final List<Tag> _pending = <Tag>[];

  bool _saving = false;

  String? _normalizeTag(String input) {
    var t = input.trim();
    if (t.isEmpty) return null;
    if (t.startsWith('#')) t = t.substring(1);
    t = t.trim();
    if (t.isEmpty) return null;
    if (t.contains(RegExp(r'\s'))) return null; // 空白禁止
    return t;
  }

  void _addPendingTag() {
    final name = _normalizeTag(_tagCtrl.text);
    if (name == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('タグが無効です（空白なしで入力してください）')),
      );
      return;
    }

    final tag = Tag(name: name, category: _selectedCategory);

    // 重複（同カテゴリ・同名）を避ける
    final exists = _pending.any(
      (t) => t.category == tag.category && t.name == tag.name,
    );
    if (exists) {
      _tagCtrl.clear();
      return;
    }

    setState(() {
      _pending.add(tag);
      _tagCtrl.clear();
    });
  }

  Future<void> _save() async {
    if (_pending.isEmpty) {
      Navigator.pop(context);
      return;
    }

    setState(() => _saving = true);
    try {
      // タグごとに一括付与（TagService 側が batch で速い）
      for (final tag in _pending) {
        await widget.tagService.addTagToItems(widget.items, tag);
      }
      if (!mounted) return;
      Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _catLabel(TagCategory c) {
    switch (c) {
      case TagCategory.artist:
        return '作者';
      case TagCategory.series:
        return 'シリーズ';
      case TagCategory.mediaType:
        return '媒体';
      case TagCategory.character:
        return 'キャラ';
      case TagCategory.free:
        return '自由';
    }
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.items.length;

    return Scaffold(
      appBar: AppBar(
        title: Text('取り込み後タグ付け（$count件）'),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: const Text('スキップ'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // カテゴリ + 入力
            Row(
              children: [
                DropdownButton<TagCategory>(
                  value: _selectedCategory,
                  onChanged: _saving
                      ? null
                      : (v) => setState(() => _selectedCategory = v!),
                  items: TagCategory.values
                      .map(
                        (c) => DropdownMenuItem(
                          value: c,
                          child: Text(_catLabel(c)),
                        ),
                      )
                      .toList(growable: false),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _tagCtrl,
                    enabled: !_saving,
                    decoration: const InputDecoration(
                      hintText: '#タグ（空白なし）',
                    ),
                    onSubmitted: (_) => _addPendingTag(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _saving ? null : _addPendingTag,
                  child: const Text('追加'),
                ),
              ],
            ),

            const SizedBox(height: 12),

            Text(
              '付与予定',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),

            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _pending.isEmpty
                  ? [
                      const Text('（まだありません）'),
                    ]
                  : _pending.map((t) {
                      return InputChip(
                        label: Text('${_catLabel(t.category)}: ${t.name}'),
                        onDeleted: _saving
                            ? null
                            : () => setState(() => _pending.remove(t)),
                      );
                    }).toList(growable: false),
            ),

            const Spacer(),

            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sell),
                label: Text(_saving ? '保存中…' : 'この$count件にタグ付け'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}