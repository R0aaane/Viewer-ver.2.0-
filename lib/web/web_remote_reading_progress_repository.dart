import '../models/reading_progress.dart';
import '../repository/reading_progress_repository.dart';
import 'web_remote_api_client.dart';

class WebRemoteReadingProgressRepository implements ReadingProgressRepository {
  final WebRemoteApiClient _client;

  const WebRemoteReadingProgressRepository(this._client);

  @override
  Future<ReadingProgressEntry?> fetchProgress(String mediaId) {
    return _client.fetchReadingProgress(mediaId);
  }

  @override
  Future<List<ReadingProgressEntry>> fetchRecent({int limit = 24}) {
    return _client.fetchRecentReadingProgress(limit: limit);
  }

  @override
  Future<ReadingProgressEntry> saveProgress(ReadingProgressSaveRequest request) {
    return _client.upsertReadingProgress(
      request.mediaId,
      currentPage: request.currentPage,
      totalPages: request.totalPages,
      progress: request.progress,
      lastReadAt: request.lastReadAt,
      updatedAt: request.updatedAt,
      identity: request.identity,
    );
  }
}
