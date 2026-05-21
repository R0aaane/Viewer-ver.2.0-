enum SavedMediaViewerSourceType {
  gallery,
  author,
  search,
}

class SavedMediaViewerContext {
  const SavedMediaViewerContext({
    required this.recordIds,
    required this.initialIndex,
    required this.sourceType,
    required this.sourceTitle,
  });

  final List<String> recordIds;
  final int initialIndex;
  final SavedMediaViewerSourceType sourceType;
  final String? sourceTitle;
}
