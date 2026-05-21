import 'media_post.dart';

class TimelinePage {
  const TimelinePage({
    required this.posts,
    required this.newestId,
    required this.nextCursor,
    required this.resultCount,
  });

  final List<MediaPost> posts;
  final String? newestId;
  final String? nextCursor;
  final int resultCount;

  bool get hasNextPage => (nextCursor ?? '').isNotEmpty;

  static const empty = TimelinePage(
    posts: [],
    newestId: null,
    nextCursor: null,
    resultCount: 0,
  );
}
