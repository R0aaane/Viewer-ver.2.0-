import 'package:flutter/material.dart';

import '../models/tag.dart';

const galleryTagCategoryLabels = {
  TagCategory.artist: 'アーティスト',
  TagCategory.character: 'キャラ',
  TagCategory.series: 'シリーズ',
};

bool matchesGalleryTags(Iterable<Tag> tags, Iterable<Tag> filters) =>
    filters.every(
      (filter) => tags.any(
        (tag) =>
            tag.category == filter.category &&
            tag.name.trim().toLowerCase() == filter.name.trim().toLowerCase(),
      ),
    );

class GalleryTagCandidate {
  final Tag tag;
  final int count;
  const GalleryTagCandidate(this.tag, this.count);
}

/// Count each PDF once, even when duplicate tags occur in its metadata.
List<GalleryTagCandidate> galleryTagCandidates(
  Iterable<Iterable<Tag>> pdfTags,
) {
  final counts = <(TagCategory, String), int>{};
  final tags = <(TagCategory, String), Tag>{};
  for (final itemTags in pdfTags) {
    final seen = <(TagCategory, String)>{};
    for (final tag in itemTags) {
      final name = tag.name.trim();
      if (name.isEmpty || !galleryTagCategoryLabels.containsKey(tag.category)) {
        continue;
      }
      final key = (tag.category, name.toLowerCase());
      if (!seen.add(key)) continue;
      tags.putIfAbsent(key, () => Tag(name: name, category: tag.category));
      counts.update(key, (count) => count + 1, ifAbsent: () => 1);
    }
  }
  return [
    for (final key in counts.keys)
      GalleryTagCandidate(tags[key]!, counts[key]!),
  ];
}

class GalleryTagPicker extends StatefulWidget {
  final List<GalleryTagCandidate> candidates;
  final Map<TagCategory, Tag> selected;
  const GalleryTagPicker({
    super.key,
    required this.candidates,
    required this.selected,
  });

  @override
  State<GalleryTagPicker> createState() => _GalleryTagPickerState();
}

class _GalleryTagPickerState extends State<GalleryTagPicker> {
  TagCategory _category = TagCategory.artist;
  String _query = '';
  bool _byName = false;

  @override
  Widget build(BuildContext context) {
    final options = widget.candidates
        .where(
          (candidate) =>
              candidate.tag.category == _category &&
              candidate.tag.name.toLowerCase().contains(
                _query.trim().toLowerCase(),
              ),
        )
        .toList();
    options.sort((a, b) {
      final count = _byName ? 0 : b.count.compareTo(a.count);
      return count != 0
          ? count
          : a.tag.name.toLowerCase().compareTo(b.tag.name.toLowerCase());
    });
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: SizedBox(
        width: 520,
        height: 560,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.manage_search_outlined),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'タグから探す',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: '閉じる',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const Text('現在のフォルダ内のPDFから選択します。'),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final entry in galleryTagCategoryLabels.entries)
                    ChoiceChip(
                      label: Text(entry.value),
                      selected: _category == entry.key,
                      onSelected: (_) => setState(() => _category = entry.key),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                decoration: const InputDecoration(
                  labelText: '名前の一部で絞り込み',
                  hintText: '未入力でも一覧から選べます',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
              Row(
                children: [
                  Expanded(child: Text('${options.length}候補')),
                  DropdownButton<bool>(
                    value: _byName,
                    items: const [
                      DropdownMenuItem(value: false, child: Text('件数順')),
                      DropdownMenuItem(value: true, child: Text('名前順')),
                    ],
                    onChanged: (value) => setState(() => _byName = value!),
                  ),
                ],
              ),
              const Divider(height: 1),
              Expanded(
                child: options.isEmpty
                    ? const Center(
                        child: Text(
                          '該当するタグがありません。\nカテゴリや入力内容を変更してください。',
                          textAlign: TextAlign.center,
                        ),
                      )
                    : ListView.builder(
                        itemCount: options.length,
                        itemBuilder: (context, index) {
                          final option = options[index];
                          final selected = widget.selected[_category];
                          final active =
                              selected != null &&
                              matchesGalleryTags([option.tag], [selected]);
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                            ),
                            selected: active,
                            leading: Icon(
                              active ? Icons.check_circle : Icons.label_outline,
                            ),
                            title: Text(option.tag.name),
                            trailing: Text(
                              '${option.count}件',
                              style: Theme.of(context).textTheme.labelLarge,
                            ),
                            onTap: () => Navigator.pop(context, option.tag),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
