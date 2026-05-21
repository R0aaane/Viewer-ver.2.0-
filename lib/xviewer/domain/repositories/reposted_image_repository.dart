import '../models/media_post.dart';
import '../models/timeline_page.dart';

abstract interface class RepostedImageRepository {
  Future<TimelinePage> fetchInitial();
  Future<TimelinePage> fetchNewer({
    String? sinceId,
    String requestReason = 'manual_refresh',
  });
  Future<TimelinePage> fetchNext({required String paginationToken});
  List<MediaPost> mergeAndDedupePosts(
    List<MediaPost> current,
    List<MediaPost> incoming,
  );
}
