import 'package:flutter/material.dart';

import '../models/saved_media_filter_state.dart';

class SavedMediaFilterBar extends StatelessWidget {
  const SavedMediaFilterBar({
    super.key,
    required this.filter,
    required this.authors,
    required this.suggestedTags,
    required this.tagQueryController,
    required this.onSelectAuthor,
    required this.onToggleFavoritesOnly,
    required this.onTagQueryChanged,
    required this.onClearFilters,
  });

  final SavedMediaFilterState filter;
  final List<String> authors;
  final List<String> suggestedTags;
  final TextEditingController tagQueryController;
  final ValueChanged<String?> onSelectAuthor;
  final VoidCallback onToggleFavoritesOnly;
  final ValueChanged<String> onTagQueryChanged;
  final VoidCallback onClearFilters;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 220,
                child: OutlinedButton.icon(
                  onPressed: () => _showAuthorPicker(context),
                  icon: const Icon(Icons.person_search_rounded),
                  label: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      filter.authorUsername == null
                          ? 'All authors'
                          : '@${filter.authorUsername}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 14,
                    ),
                    alignment: Alignment.centerLeft,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 260,
                child: TextFormField(
                  controller: tagQueryController,
                  decoration: const InputDecoration(
                    labelText: 'Search tag',
                    hintText: 'art, ref, memo...',
                    prefixIcon: Icon(Icons.tag_rounded),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: onTagQueryChanged,
                ),
              ),
              FilterChip(
                selected: filter.onlyFavorites,
                onSelected: (_) => onToggleFavoritesOnly(),
                label: const Text('Favorites only'),
                avatar: const Icon(Icons.favorite_border),
              ),
              if (filter.hasActiveFilters)
                TextButton.icon(
                  onPressed: onClearFilters,
                  icon: const Icon(Icons.clear_rounded),
                  label: const Text('Clear'),
                ),
            ],
          ),
          if (suggestedTags.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: suggestedTags.take(12).map((tag) {
                final isActive = filter.tagQuery == tag;
                return ActionChip(
                  onPressed: () => onTagQueryChanged(isActive ? '' : tag),
                  label: Text('#$tag'),
                  backgroundColor: isActive
                      ? theme.colorScheme.secondaryContainer
                      : null,
                );
              }).toList(growable: false),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _showAuthorPicker(BuildContext context) async {
    final grouped = groupAuthors(authors);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        final theme = Theme.of(context);
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.72,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.people_alt_rounded),
                  title: const Text('Authors'),
                  subtitle: const Text('Sorted alphabetically'),
                  trailing: TextButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      onSelectAuthor(null);
                    },
                    child: const Text('All'),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    itemCount: grouped.entries.length,
                    itemBuilder: (context, index) {
                      final section = grouped.entries.elementAt(index);
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                            color: theme.colorScheme.secondaryContainer,
                            child: Text(
                              section.key,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          ...section.value.map((author) {
                            return ListTile(
                              dense: true,
                              leading: const Icon(Icons.person_outline_rounded),
                              title: Text(
                                '@$author',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              selected: filter.authorUsername == author,
                              onTap: () {
                                Navigator.of(context).pop();
                                onSelectAuthor(author);
                              },
                            );
                          }),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

Map<String, List<String>> groupAuthors(List<String> authors) {
  final sorted = [...authors]
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  final grouped = <String, List<String>>{};

  for (final author in sorted) {
    final key = getAuthorSectionKey(author);
    grouped.putIfAbsent(key, () => <String>[]).add(author);
  }

  return grouped;
}

String getAuthorSectionKey(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) {
    return '#';
  }
  final first = trimmed[0].toUpperCase();
  final isAsciiLetter = RegExp(r'^[A-Z]$').hasMatch(first);
  return isAsciiLetter ? first : '#';
}
