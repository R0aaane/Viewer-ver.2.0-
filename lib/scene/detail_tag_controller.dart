part of 'detailImage.dart';

class DetailTagController {
  final TextEditingController assignedFilterCtrl = TextEditingController();
  final TextEditingController masterFilterCtrl = TextEditingController();
  final TextEditingController tagCtrl = TextEditingController();

  final Map<String, bool> tagGroupExpanded = <String, bool>{};
  final Map<String, int> candidateVisibleCounts = <String, int>{};

  Timer? masterFilterDebounce;
  TagCategory selectedCategory = TagCategory.free;

  void dispose() {
    masterFilterDebounce?.cancel();
    assignedFilterCtrl.dispose();
    masterFilterCtrl.dispose();
    tagCtrl.dispose();
  }

  String? normalizeTag(String input) {
    var tag = input.trim();
    if (tag.isEmpty) {
      return null;
    }
    if (tag.startsWith('#')) {
      tag = tag.substring(1);
    }
    tag = tag.trim();
    if (tag.isEmpty || tag.contains(RegExp(r'\s'))) {
      return null;
    }
    return tag;
  }

  String serializeRecentTag(Tag tag) => '${tag.category.name}\u0001${tag.name}';

  Tag? deserializeRecentTag(String raw) {
    final separatorIndex = raw.indexOf('\u0001');
    if (separatorIndex <= 0 || separatorIndex >= raw.length - 1) {
      return null;
    }
    final categoryRaw = raw.substring(0, separatorIndex);
    final name = raw.substring(separatorIndex + 1).trim();
    if (name.isEmpty) {
      return null;
    }
    for (final category in TagCategory.values) {
      if (category.name == categoryRaw) {
        return Tag(name: name, category: category);
      }
    }
    return null;
  }

  String? tagLookupKey(Tag tag) {
    final normalizedName = tag.name.trim();
    if (normalizedName.isEmpty) {
      return null;
    }
    return '${tag.category.name}\u0000${normalizedName.toLowerCase()}';
  }

  List<TagCategory> get orderedTagCategories => const <TagCategory>[
    TagCategory.artist,
    TagCategory.series,
    TagCategory.character,
    TagCategory.mediaType,
    TagCategory.free,
  ];

  int categoryOrder(TagCategory category) {
    final index = orderedTagCategories.indexOf(category);
    return index < 0 ? orderedTagCategories.length : index;
  }

  String categoryLabel(TagCategory category) {
    switch (category) {
      case TagCategory.artist:
        return 'artist';
      case TagCategory.series:
        return 'series';
      case TagCategory.mediaType:
        return 'source';
      case TagCategory.character:
        return 'character';
      case TagCategory.free:
        return 'free';
    }
  }

  String categoryLongLabel(TagCategory category) {
    switch (category) {
      case TagCategory.artist:
        return 'artist';
      case TagCategory.series:
        return 'series';
      case TagCategory.mediaType:
        return 'source / media';
      case TagCategory.character:
        return 'character';
      case TagCategory.free:
        return 'free';
    }
  }

  IconData categoryIcon(TagCategory category) {
    switch (category) {
      case TagCategory.artist:
        return Icons.palette_outlined;
      case TagCategory.series:
        return Icons.collections_bookmark_outlined;
      case TagCategory.mediaType:
        return Icons.public_outlined;
      case TagCategory.character:
        return Icons.face_retouching_natural_outlined;
      case TagCategory.free:
        return Icons.sell_outlined;
    }
  }

  Color categoryColor(TagCategory category) {
    switch (category) {
      case TagCategory.artist:
        return const Color(0xFFE0A15A);
      case TagCategory.series:
        return const Color(0xFF53B889);
      case TagCategory.mediaType:
        return const Color(0xFF4CA3D9);
      case TagCategory.character:
        return const Color(0xFF6D8CFF);
      case TagCategory.free:
        return const Color(0xFFC987A6);
    }
  }

  List<TagWithId> sortTagWithIdList(Iterable<TagWithId> source) {
    final list = source.toList(growable: false);
    list.sort((a, b) {
      final categoryCompare = categoryOrder(
        a.tag.category,
      ).compareTo(categoryOrder(b.tag.category));
      if (categoryCompare != 0) {
        return categoryCompare;
      }
      return a.tag.name.toLowerCase().compareTo(b.tag.name.toLowerCase());
    });
    return list;
  }

  List<TagWithId> filteredAssignedTags(List<TagWithId> tags) {
    final query = assignedFilterCtrl.text.trim().toLowerCase();
    final filtered = tags.where((entry) {
      if (query.isEmpty) {
        return true;
      }
      return entry.tag.name.toLowerCase().contains(query) ||
          categoryLabel(entry.tag.category).contains(query);
    });
    return sortTagWithIdList(filtered);
  }

  Map<TagCategory, List<TagWithId>> groupAssignedTags(List<TagWithId> tags) {
    final grouped = <TagCategory, List<TagWithId>>{};
    for (final entry in filteredAssignedTags(tags)) {
      grouped.putIfAbsent(entry.tag.category, () => <TagWithId>[]).add(entry);
    }
    return grouped;
  }

  bool matchesMasterFilter(Tag tag) {
    final query = masterFilterCtrl.text.trim().toLowerCase();
    if (query.isEmpty) {
      return true;
    }
    return tag.name.toLowerCase().contains(query) ||
        categoryLabel(tag.category).contains(query);
  }

  int tagNameMatchRank(Tag tag) {
    final query = masterFilterCtrl.text.trim().toLowerCase();
    if (query.isEmpty) {
      return 2;
    }
    final name = tag.name.toLowerCase();
    if (name == query) {
      return 0;
    }
    if (name.startsWith(query)) {
      return 1;
    }
    return 2;
  }

  bool isGroupExpanded(String key, {required bool defaultValue}) {
    return tagGroupExpanded[key] ?? defaultValue;
  }

  void toggleGroupExpanded(String key, {required bool defaultValue}) {
    tagGroupExpanded[key] = !isGroupExpanded(key, defaultValue: defaultValue);
  }

  int visibleCandidateCount({
    required _TagSuggestionTab tab,
    required TagCategory category,
    required int total,
  }) {
    final key = '${tab.name}:${category.name}';
    final count = candidateVisibleCounts[key] ?? 12;
    return count > total ? total : count;
  }

  void showMoreCandidates(_TagSuggestionTab tab, TagCategory category) {
    final key = '${tab.name}:${category.name}';
    candidateVisibleCounts[key] = (candidateVisibleCounts[key] ?? 12) + 12;
  }
}
