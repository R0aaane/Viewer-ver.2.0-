enum SavedMediaSort { savedAtDesc }

class SavedMediaFilterState {
  const SavedMediaFilterState({
    this.authorUsername,
    this.onlyFavorites = false,
    this.tagQuery = '',
    this.sort = SavedMediaSort.savedAtDesc,
  });

  final String? authorUsername;
  final bool onlyFavorites;
  final String tagQuery;
  final SavedMediaSort sort;

  bool get hasActiveFilters =>
      (authorUsername?.isNotEmpty ?? false) || onlyFavorites || tagQuery.isNotEmpty;

  SavedMediaFilterState copyWith({
    String? authorUsername,
    bool clearAuthor = false,
    bool? onlyFavorites,
    String? tagQuery,
    SavedMediaSort? sort,
  }) {
    return SavedMediaFilterState(
      authorUsername: clearAuthor ? null : (authorUsername ?? this.authorUsername),
      onlyFavorites: onlyFavorites ?? this.onlyFavorites,
      tagQuery: tagQuery ?? this.tagQuery,
      sort: sort ?? this.sort,
    );
  }

  SavedMediaFilterState clear() {
    return const SavedMediaFilterState();
  }
}
