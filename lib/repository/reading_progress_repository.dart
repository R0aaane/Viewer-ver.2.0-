import '../models/reading_progress.dart';

abstract class ReadingProgressRepository {
  Future<ReadingProgressEntry?> fetchProgress(String mediaId);

  Future<List<ReadingProgressEntry>> fetchRecent({int limit = 24});

  Future<ReadingProgressEntry> saveProgress(ReadingProgressSaveRequest request);
}
