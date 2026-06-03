import '../models/reading_progress.dart';
import '../repository/reading_progress_repository.dart';

class ReadingProgressService {
  final ReadingProgressRepository _repository;

  const ReadingProgressService(this._repository);

  Future<ReadingProgressEntry?> fetchProgress(String mediaId) {
    return _repository.fetchProgress(mediaId);
  }

  Future<List<ReadingProgressEntry>> fetchRecent({int limit = 24}) {
    return _repository.fetchRecent(limit: limit);
  }

  Future<ReadingProgressEntry> saveProgress({
    required String mediaId,
    required int currentPage,
    int? totalPages,
    DateTime? lastReadAt,
    DateTime? updatedAt,
    Map<String, dynamic>? identity,
    bool? isBookmarked,
  }) {
    final normalizedTotalPages =
        totalPages != null && totalPages > 0 ? totalPages : null;
    final normalizedCurrentPage = currentPage < 1 ? 1 : currentPage;
    final clampedCurrentPage =
        normalizedTotalPages != null &&
            normalizedCurrentPage > normalizedTotalPages
        ? normalizedTotalPages
        : normalizedCurrentPage;
    final normalizedLastReadAt = (lastReadAt ?? DateTime.now()).toUtc();
    final normalizedUpdatedAt = (updatedAt ?? normalizedLastReadAt).toUtc();
    final progress =
        normalizedTotalPages != null && normalizedTotalPages > 0
        ? (clampedCurrentPage / normalizedTotalPages).clamp(0.0, 1.0).toDouble()
        : 0.0;

    return _repository.saveProgress(
      ReadingProgressSaveRequest(
        mediaId: mediaId,
        currentPage: clampedCurrentPage,
        totalPages: normalizedTotalPages,
        progress: progress,
        lastReadAt: normalizedLastReadAt,
        updatedAt: normalizedUpdatedAt,
        identity: identity,
        isBookmarked: isBookmarked,
      ),
    );
  }

  static bool shouldShowContinueCard(ReadingProgressEntry entry) {
    return entry.hasResumePosition && !entry.isCompleted;
  }
}
