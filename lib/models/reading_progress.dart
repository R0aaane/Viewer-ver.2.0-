class ReadingProgressEntry {
  final String mediaId;
  final String title;
  final String folderRaw;
  final int currentPage;
  final int? totalPages;
  final double progress;
  final DateTime lastReadAt;
  final DateTime updatedAt;
  final String? thumbnailUrl;
  final bool isBookmarked;

  const ReadingProgressEntry({
    required this.mediaId,
    required this.title,
    required this.folderRaw,
    required this.currentPage,
    required this.totalPages,
    required this.progress,
    required this.lastReadAt,
    required this.updatedAt,
    required this.thumbnailUrl,
    this.isBookmarked = false,
  });

  bool get hasResumePosition => currentPage > 1;

  bool get isCompleted =>
      totalPages != null && totalPages! > 0 && currentPage >= totalPages!;
}

class ReadingProgressSaveRequest {
  final String mediaId;
  final int currentPage;
  final int? totalPages;
  final double progress;
  final DateTime lastReadAt;
  final DateTime updatedAt;
  final Map<String, dynamic>? identity;
  final bool? isBookmarked;

  const ReadingProgressSaveRequest({
    required this.mediaId,
    required this.currentPage,
    required this.totalPages,
    required this.progress,
    required this.lastReadAt,
    required this.updatedAt,
    this.identity,
    this.isBookmarked,
  });
}
