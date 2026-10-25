import 'dart:math';
import 'dart:typed_data';

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
  final int? previewIndex;
  const GalleryTagCandidate(this.tag, this.count, {this.previewIndex});
}

/// Count each PDF once, even when duplicate tags occur in its metadata.
List<GalleryTagCandidate> galleryTagCandidates(
  Iterable<Iterable<Tag>> pdfTags, {
  Random? random,
}) {
  final rng = random ?? Random();
  final counts = <(TagCategory, String), int>{};
  final tags = <(TagCategory, String), Tag>{};
  final previews = <(TagCategory, String), int>{};
  var index = -1;
  for (final itemTags in pdfTags) {
    index++;
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
      // Reservoir sampling: one representative without storing every match.
      if (rng.nextInt(counts[key]!) == 0) previews[key] = index;
    }
  }
  return [
    for (final key in counts.keys)
      GalleryTagCandidate(
        tags[key]!,
        counts[key]!,
        previewIndex: previews[key],
      ),
  ];
}

class GalleryTagPicker extends StatefulWidget {
  final List<GalleryTagCandidate> candidates;
  final Map<TagCategory, Tag> selected;
  final Future<Uint8List> Function(int index)? loadThumbnail;
  const GalleryTagPicker({
    super.key,
    required this.candidates,
    required this.selected,
    this.loadThumbnail,
  });

  @override
  State<GalleryTagPicker> createState() => _GalleryTagPickerState();
}

class _GalleryTagPickerState extends State<GalleryTagPicker> {
  TagCategory _category = TagCategory.artist;
  String _query = '';
  bool _byName = false;
  final Map<(TagCategory, bool), List<GalleryTagCandidate>> _sorted = {};
  final _previewCache = <int, Uint8List>{};
  final _previewLanes = [Future<void>.value(), Future<void>.value()];
  var _nextLane = 0;

  Future<Uint8List?> _loadPreview(int index, bool Function() visible) {
    final lane = _nextLane++ % _previewLanes.length;
    final future = _previewLanes[lane].then((_) async {
      if (!mounted || !visible()) return null;
      final cached = _previewCache.remove(index);
      if (cached != null) {
        _previewCache[index] = cached;
        return cached;
      }
      try {
        final bytes = await widget.loadThumbnail!(index);
        if (!mounted) return null;
        _previewCache[index] = bytes;
        while (_previewCache.length > 32) {
          _previewCache.remove(_previewCache.keys.first);
        }
        return bytes;
      } catch (_) {
        return null;
      }
    });
    _previewLanes[lane] = future.then<void>((_) {});
    return future;
  }

  @override
  void didUpdateWidget(covariant GalleryTagPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.candidates, widget.candidates)) {
      _sorted.clear();
      _previewCache.clear();
    }
  }

  List<GalleryTagCandidate> _sortedCandidates() =>
      _sorted.putIfAbsent((_category, _byName), () {
        final candidates = widget.candidates
            .where((candidate) => candidate.tag.category == _category)
            .toList();
        candidates.sort((a, b) {
          final count = _byName ? 0 : b.count.compareTo(a.count);
          return count != 0
              ? count
              : a.tag.name.toLowerCase().compareTo(b.tag.name.toLowerCase());
        });
        return candidates;
      });

  @override
  Widget build(BuildContext context) {
    final needle = _query.trim().toLowerCase();
    final options = _sortedCandidates()
        .where((candidate) => candidate.tag.name.toLowerCase().contains(needle))
        .toList();
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
                        cacheExtent: 0,
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
                            leading:
                                widget.loadThumbnail != null &&
                                    option.previewIndex != null
                                ? _TagPreview(
                                    key: ValueKey((
                                      option.tag.category,
                                      option.tag.name,
                                      option.previewIndex,
                                    )),
                                    index: option.previewIndex!,
                                    load: _loadPreview,
                                  )
                                : const Icon(Icons.label_outline),
                            title: Text(option.tag.name),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (active)
                                  const Padding(
                                    padding: EdgeInsets.only(right: 6),
                                    child: Icon(Icons.check_circle, size: 18),
                                  ),
                                Text(
                                  '${option.count}件',
                                  style: Theme.of(context).textTheme.labelLarge,
                                ),
                              ],
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

class _TagPreview extends StatefulWidget {
  final int index;
  final Future<Uint8List?> Function(int, bool Function()) load;
  const _TagPreview({super.key, required this.index, required this.load});

  @override
  State<_TagPreview> createState() => _TagPreviewState();
}

class _TagPreviewState extends State<_TagPreview> {
  late final Future<Uint8List?> _image;

  @override
  void initState() {
    super.initState();
    _image = Future<Uint8List?>.delayed(const Duration(milliseconds: 100), () {
      if (!mounted) return null;
      return widget.load(widget.index, () => mounted);
    });
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 40,
    height: 52,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: FutureBuilder<Uint8List?>(
          future: _image,
          builder: (context, snapshot) {
            const placeholder = Icon(Icons.picture_as_pdf_outlined, size: 22);
            final bytes = snapshot.data;
            return bytes == null
                ? placeholder
                : Image.memory(
                    bytes,
                    fit: BoxFit.cover,
                    cacheWidth: 80,
                    cacheHeight: 104,
                    excludeFromSemantics: true,
                    errorBuilder: (_, _, _) => placeholder,
                  );
          },
        ),
      ),
    ),
  );
}
