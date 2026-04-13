import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/tag.dart';

class TagAliasService {
  static const String _assetPath = 'assets/config/tag_aliases.json';
  static Future<TagAliasService>? _defaultFuture;

  final Map<TagCategory, List<_TagAliasGroup>> _groupsByCategory;
  final Map<String, _TagAliasGroup> _groupsByLookupKey;

  TagAliasService._(
    this._groupsByCategory,
    this._groupsByLookupKey,
  );

  factory TagAliasService.empty() {
    return TagAliasService._(
      <TagCategory, List<_TagAliasGroup>>{},
      <String, _TagAliasGroup>{},
    );
  }

  static Future<TagAliasService> loadDefault() {
    return _defaultFuture ??= _loadDefaultInternal();
  }

  static Future<TagAliasService> _loadDefaultInternal() async {
    try {
      final rawJson = await rootBundle.loadString(_assetPath);
      return TagAliasService.fromJsonString(rawJson);
    } catch (error, stackTrace) {
      debugPrint('[TagAliasService] Failed to load $_assetPath: $error');
      debugPrintStack(
        label: '[TagAliasService] loadDefault',
        stackTrace: stackTrace,
      );
      return TagAliasService.empty();
    }
  }

  factory TagAliasService.fromJsonString(String rawJson) {
    final decoded = jsonDecode(rawJson);
    if (decoded is! Map) {
      return TagAliasService.empty();
    }

    final groupsByCategory = <TagCategory, List<_TagAliasGroup>>{};
    final groupsByLookupKey = <String, _TagAliasGroup>{};

    for (final category in _supportedCategories) {
      final categoryMap = decoded[_categoryKey(category)];
      if (categoryMap is! Map) {
        continue;
      }

      final groups = <_TagAliasGroup>[];
      for (final entry in categoryMap.entries) {
        final rawCanonical = entry.key.toString();
        final aliases = switch (entry.value) {
          List<dynamic> values => values.map((value) => value.toString()).toList(),
          String value => <String>[value],
          _ => const <String>[],
        };
        final group = _TagAliasGroup.create(
          category: category,
          canonical: rawCanonical,
          aliases: aliases,
        );
        if (group == null) {
          continue;
        }
        groups.add(group);
        for (final candidate in group.allNames) {
          groupsByLookupKey[_lookupKey(category, candidate)] = group;
        }
      }

      if (groups.isNotEmpty) {
        groupsByCategory[category] = groups;
      }
    }

    return TagAliasService._(groupsByCategory, groupsByLookupKey);
  }

  bool get isConfigured => _groupsByLookupKey.isNotEmpty;

  bool supportsCategory(TagCategory category) {
    return (_groupsByCategory[category] ?? const <_TagAliasGroup>[]).isNotEmpty;
  }

  String canonicalizeName(TagCategory category, String rawName) {
    final trimmed = rawName.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    final group = _groupsByLookupKey[_lookupKey(category, trimmed)];
    return group?.canonical ?? trimmed;
  }

  Tag canonicalizeTag(Tag tag) {
    final canonicalName = canonicalizeName(tag.category, tag.name);
    return Tag(
      name: canonicalName.isEmpty ? tag.name.trim() : canonicalName,
      category: tag.category,
    );
  }

  List<Tag> canonicalizeTags(Iterable<Tag> tags) {
    final out = <Tag>[];
    final seen = <String>{};
    for (final tag in tags) {
      final canonical = canonicalizeTag(tag);
      final trimmed = canonical.name.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      final key = '${canonical.category.name}\u0000${trimmed.toLowerCase()}';
      if (!seen.add(key)) {
        continue;
      }
      out.add(Tag(name: trimmed, category: canonical.category));
    }
    return out;
  }

  List<String> equivalentNames(
    TagCategory category,
    String rawName, {
    bool partial = false,
  }) {
    final trimmed = rawName.trim();
    if (trimmed.isEmpty) {
      return const <String>[];
    }

    final out = <String>[];
    final seen = <String>{};

    void addCandidate(String value) {
      final normalized = value.trim();
      if (normalized.isEmpty) {
        return;
      }
      final key = normalized.toLowerCase();
      if (seen.add(key)) {
        out.add(normalized);
      }
    }

    if (!supportsCategory(category)) {
      addCandidate(trimmed);
      return out;
    }

    final groups = _groupsByCategory[category] ?? const <_TagAliasGroup>[];
    if (partial) {
      final query = trimmed.toLowerCase();
      for (final group in groups) {
        if (!group.matchesPartial(query)) {
          continue;
        }
        for (final candidate in group.allNames) {
          addCandidate(candidate);
        }
      }
      addCandidate(trimmed);
      return out;
    }

    final group = _groupsByLookupKey[_lookupKey(category, trimmed)];
    if (group != null) {
      for (final candidate in group.allNames) {
        addCandidate(candidate);
      }
      return out;
    }

    addCandidate(trimmed);
    return out;
  }

  List<String> equivalentNamesAcrossAliasCategories(
    String rawName, {
    bool partial = false,
  }) {
    final trimmed = rawName.trim();
    if (trimmed.isEmpty) {
      return const <String>[];
    }

    final out = <String>[];
    final seen = <String>{};

    void addCandidate(String value) {
      final normalized = value.trim();
      if (normalized.isEmpty) {
        return;
      }
      final key = normalized.toLowerCase();
      if (seen.add(key)) {
        out.add(normalized);
      }
    }

    for (final category in _supportedCategories) {
      for (final candidate
          in equivalentNames(category, trimmed, partial: partial)) {
        addCandidate(candidate);
      }
    }

    if (out.isEmpty) {
      addCandidate(trimmed);
    }
    return out;
  }

  bool matchesTagName(
    TagCategory category,
    String candidateName,
    String query, {
    bool partial = false,
  }) {
    final normalizedCandidate = candidateName.trim().toLowerCase();
    if (normalizedCandidate.isEmpty) {
      return false;
    }

    final searchTerms = equivalentNames(category, query, partial: partial);
    if (searchTerms.isEmpty) {
      return false;
    }

    if (partial) {
      return searchTerms.any(
        (term) => normalizedCandidate.contains(term.trim().toLowerCase()),
      );
    }

    return searchTerms.any(
      (term) => normalizedCandidate == term.trim().toLowerCase(),
    );
  }

  bool matchesContains(
    TagCategory category,
    String candidateName,
    String contains,
  ) {
    final normalizedContains = contains.trim().toLowerCase();
    if (normalizedContains.isEmpty) {
      return true;
    }

    final group = _groupsByLookupKey[_lookupKey(category, candidateName)];
    if (group == null) {
      return candidateName.trim().toLowerCase().contains(normalizedContains);
    }

    return group.allNames.any(
      (candidate) => candidate.trim().toLowerCase().contains(normalizedContains),
    );
  }

  static const List<TagCategory> _supportedCategories = <TagCategory>[
    TagCategory.series,
    TagCategory.character,
  ];

  static String _categoryKey(TagCategory category) {
    switch (category) {
      case TagCategory.artist:
        return 'artist';
      case TagCategory.series:
        return 'series';
      case TagCategory.mediaType:
        return 'mediaType';
      case TagCategory.character:
        return 'character';
      case TagCategory.free:
        return 'free';
    }
  }

  static String _lookupKey(TagCategory category, String rawName) {
    return '${category.name}\u0000${rawName.trim().toLowerCase()}';
  }
}

class _TagAliasGroup {
  final TagCategory category;
  final String canonical;
  final List<String> aliases;
  final List<String> allNames;

  const _TagAliasGroup({
    required this.category,
    required this.canonical,
    required this.aliases,
    required this.allNames,
  });

  static _TagAliasGroup? create({
    required TagCategory category,
    required String canonical,
    required List<String> aliases,
  }) {
    final normalizedCanonical = canonical.trim();
    if (normalizedCanonical.isEmpty) {
      return null;
    }

    final out = <String>[];
    final seen = <String>{};

    void addValue(String value) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) {
        return;
      }
      final key = trimmed.toLowerCase();
      if (seen.add(key)) {
        out.add(trimmed);
      }
    }

    addValue(normalizedCanonical);
    for (final alias in aliases) {
      addValue(alias);
    }

    if (out.isEmpty) {
      return null;
    }

    return _TagAliasGroup(
      category: category,
      canonical: normalizedCanonical,
      aliases: out.where((value) => value != normalizedCanonical).toList(),
      allNames: out,
    );
  }

  bool matchesPartial(String normalizedQuery) {
    if (normalizedQuery.isEmpty) {
      return true;
    }
    return allNames.any(
      (candidate) => candidate.trim().toLowerCase().contains(normalizedQuery),
    );
  }
}
