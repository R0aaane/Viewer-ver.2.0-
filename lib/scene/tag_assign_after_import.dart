import 'dart:async';

import 'package:flutter/material.dart';

import '../database/tag_service.dart';
import '../models/mediaItem.dart';
import '../models/tag.dart' as model;
import 'widgets/scene_ui.dart';

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

  final List<model.Tag> _pending = <model.Tag>[];
  List<TagWithId> _master = <TagWithId>[];

  bool _loadingMaster = false;
  bool _saving = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _refreshMaster();
    _tagCtrl.addListener(_handleTagTextChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _tagCtrl
      ..removeListener(_handleTagTextChanged)
      ..dispose();
    super.dispose();
  }

  void _handleTagTextChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) {
        _refreshMaster();
      }
    });
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
      if (mounted) {
        setState(() => _loadingMaster = false);
      }
    }
  }

  bool _isPending(model.Tag tag) {
    return _pending.any(
      (entry) => entry.category == tag.category && entry.name == tag.name,
    );
  }

  void _addExisting(model.Tag tag) {
    final next = model.Tag(name: tag.name, category: tag.category);
    if (_isPending(next)) return;
    setState(() => _pending.add(next));
  }

  String? _normalizeTag(String input) {
    var value = input.trim();
    if (value.isEmpty) return null;
    if (value.startsWith('#')) value = value.substring(1);
    value = value.trim();
    if (value.isEmpty || value.contains(RegExp(r'\s'))) {
      return null;
    }
    return value;
  }

  void _addPendingTag() {
    final name = _normalizeTag(_tagCtrl.text);
    if (name == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('タグは空白を含まない名前で入力してください')),
      );
      return;
    }

    final tag = model.Tag(name: name, category: _selectedCategory);
    if (_isPending(tag)) {
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
      for (final tag in _pending) {
        await widget.tagService.addTagToItems(widget.items, tag);
      }
      if (!mounted) return;
      Navigator.pop(context);
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  String _categoryLabel(model.TagCategory category) {
    switch (category) {
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
        title: Text('取り込み後タグ付け ($count件)'),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: const Text('スキップ'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SceneSurfaceCard(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxWidth < 560;
                    final categoryField = DropdownButtonFormField<
                        model.TagCategory>(
                      value: _selectedCategory,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'カテゴリ',
                      ),
                      onChanged: _saving
                          ? null
                          : (value) {
                              if (value == null) return;
                              setState(() => _selectedCategory = value);
                              _refreshMaster();
                            },
                      items: model.TagCategory.values
                          .map(
                            (category) => DropdownMenuItem(
                              value: category,
                              child: Text(_categoryLabel(category)),
                            ),
                          )
                          .toList(growable: false),
                    );

                    final inputField = TextField(
                      controller: _tagCtrl,
                      enabled: !_saving,
                      decoration: const InputDecoration(
                        hintText: '#タグを追加',
                      ),
                      onSubmitted: (_) => _addPendingTag(),
                    );

                    final addButton = FilledButton.icon(
                      onPressed: _saving ? null : _addPendingTag,
                      icon: const Icon(Icons.add),
                      label: const Text('追加'),
                    );

                    if (compact) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          categoryField,
                          const SizedBox(height: 12),
                          inputField,
                          const SizedBox(height: 12),
                          addButton,
                        ],
                      );
                    }

                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(width: 180, child: categoryField),
                        const SizedBox(width: 12),
                        Expanded(child: inputField),
                        const SizedBox(width: 12),
                        addButton,
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxWidth < 720;
                    final masterPanel = SceneSurfaceCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SceneSectionHeader(
                            title: '既存タグ候補',
                            trailing: _loadingMaster
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : null,
                          ),
                          Expanded(
                            child: _master.isEmpty
                                ? const SceneEmptyState(
                                    icon: Icons.label_outline,
                                    title: '候補がありません',
                                    message: '入力中の文字列やカテゴリに一致するタグは見つかりませんでした。',
                                  )
                                : ListView.separated(
                                    itemCount: _master.length,
                                    separatorBuilder: (_, __) =>
                                        const Divider(height: 1),
                                    itemBuilder: (context, index) {
                                      final tag = _master[index].tag;
                                      final pending = _isPending(tag);
                                      return ListTile(
                                        dense: true,
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                          horizontal: 4,
                                        ),
                                        title: Text(
                                          tag.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        trailing: Icon(
                                          pending ? Icons.check : Icons.add,
                                          size: 18,
                                        ),
                                        onTap: _saving || pending
                                            ? null
                                            : () => _addExisting(tag),
                                      );
                                    },
                                  ),
                          ),
                        ],
                      ),
                    );

                    final pendingPanel = SceneSurfaceCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SceneSectionHeader(title: '追加予定'),
                          Expanded(
                            child: _pending.isEmpty
                                ? const SceneEmptyState(
                                    icon: Icons.sell_outlined,
                                    title: 'まだタグは選ばれていません',
                                    message: '候補をタップするか新しいタグを追加してください。',
                                  )
                                : SingleChildScrollView(
                                    child: Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: _pending
                                          .map(
                                            (tag) => InputChip(
                                              label: Text(
                                                '${_categoryLabel(tag.category)}: ${tag.name}',
                                              ),
                                              onDeleted: _saving
                                                  ? null
                                                  : () => setState(
                                                        () => _pending.remove(
                                                          tag,
                                                        ),
                                                      ),
                                            ),
                                          )
                                          .toList(growable: false),
                                    ),
                                  ),
                          ),
                        ],
                      ),
                    );

                    if (compact) {
                      return Column(
                        children: [
                          Expanded(child: masterPanel),
                          const SizedBox(height: 12),
                          Expanded(child: pendingPanel),
                        ],
                      );
                    }

                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: masterPanel),
                        const SizedBox(width: 12),
                        Expanded(child: pendingPanel),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sell),
                label: Text(_saving ? '保存中...' : '$count件にタグ付け'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
