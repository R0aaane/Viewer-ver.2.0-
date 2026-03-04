import 'package:flutter/material.dart';

import '../database/tag_service.dart';
import '../database/tag_service.dart'; 
import '../models/mediaItem.dart';
import '../models/tag.dart' as model;

import 'dart:async';


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
  model.TagCategory _selectedCategory = model.TagCategory.artist;
  final TextEditingController _tagCtrl = TextEditingController();

  // 付与予定のタグ一覧（カテゴリ込み）
  final List<model.Tag> _pending = <model.Tag>[];

  List<TagWithId> _master = <TagWithId>[];
  bool _loadingMaster = false;
  Timer? _debounce;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _refreshMaster(); // 初回ロード

    // 入力文字で候補を絞り込む（デバウンス）
    _tagCtrl.addListener(() {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 250), () {
        if (mounted) _refreshMaster();
      });
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _tagCtrl.dispose();
    super.dispose();
  }

  Future<void> _refreshMaster() async {
    if (_saving) return;
    setState(() => _loadingMaster = true);
    try {
      final contains = _tagCtrl.text.trim();
      final rows = await widget.tagService.listTagMasterByCategory(
        _selectedCategory,
        contains: contains.isEmpty ? null : contains,
        limit: 200,
      );
      if (!mounted) return;
      setState(() => _master = rows);
    } finally {
      if (mounted) setState(() => _loadingMaster = false);
    }
  }

  bool _isPending(model.Tag t) {
    return _pending.any((x) => x.category == t.category && x.name == t.name);
  }

  // 既存タグ候補をタップ→pending追加
  void _addExisting(model.Tag tag) {
    final t = model.Tag(name: tag.name, category: tag.category);
    if (_isPending(t)) return;
    setState(() => _pending.add(t));
  }

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

    final tag = model.Tag(name: name, category: _selectedCategory);

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
    _refreshMaster();
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

  String _catLabel(model.TagCategory c) {
    switch (c) {
      case model.TagCategory.artist:
        return '作者';
      case model.TagCategory.series:
        return 'シリーズ';
      case model.TagCategory.mediaType:
        return '媒体';
      case model.TagCategory.character:
        return 'キャラ';
      case model.TagCategory.free:
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
                DropdownButton<model.TagCategory>(
                  value: _selectedCategory,
                  onChanged: _saving
                      ? null
                      : (v) {
                        setState(() => _selectedCategory = v!);
                        _refreshMaster();
                      },
                  items: model.TagCategory.values
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
            Row(
              children: [
                Text(
                  '既存タグ候補',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(width: 8),
                if (_loadingMaster)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),

            const SizedBox(height: 8),

            // 既存タグ候補リスト（スクロール可能）
            SizedBox(
              height: 160,
              child: _master.isEmpty
                  ? const Text('（該当なし）')
                  : ListView.builder(
                      itemCount: _master.length,
                      itemBuilder: (context, i) {
                        final t = _master[i].tag; // model.Tag
                        final pending = _pending.any(
                          (x) => x.category == t.category && x.name == t.name,
                        );

                        return ListTile(
                          dense: true,
                          title: Text(t.name),
                          trailing: pending
                              ? const Icon(Icons.check, size: 18)
                              : const Icon(Icons.add, size: 18),
                          onTap: _saving || pending ? null : () => _addExisting(t),
                        );
                      },
                    ),
            ),

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