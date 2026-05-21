import 'package:flutter/foundation.dart';

import '../../core/errors/x_api_exception.dart';
import '../../domain/models/auth_session.dart';
import '../../domain/models/feed_mode.dart';
import '../../domain/models/media_post.dart';
import '../../domain/models/timeline_page.dart';
import '../../domain/repositories/reposted_image_repository.dart';
import '../../services/auth_persistence_service.dart';
import '../../services/timeline_media_extractor.dart';
import '../../services/x_timeline_request_builder.dart';
import '../adapters/x_timeline_adapter.dart';
import '../datasources/x_api_client.dart';

class RepostedImageRepositoryImpl implements RepostedImageRepository {
  static const int _maxEmptyImagePagesPerLoadMore = 5;

  RepostedImageRepositoryImpl(
    this._xApiClient,
    this._adapter,
    this._extractor,
    this._authPersistenceService,
  );

  final XApiClient _xApiClient;
  final XTimelineAdapter _adapter;
  final TimelineMediaExtractor _extractor;
  final AuthPersistenceService _authPersistenceService;

  @override
  Future<TimelinePage> fetchInitial() async {
    return _fetchTimelinePage(
      requestType: TimelineRequestType.initial,
      requestReason: 'initial_load',
    );
  }

  @override
  Future<TimelinePage> fetchNewer({
    String? sinceId,
    String requestReason = 'manual_refresh',
  }) async {
    return _fetchTimelinePage(
      requestType: TimelineRequestType.newer,
      requestReason: requestReason,
      sinceId: sinceId,
    );
  }

  @override
  Future<TimelinePage> fetchNext({required String paginationToken}) async {
    return _fetchNextUntilImagePosts(
      initialPaginationToken: paginationToken,
      requestReason: 'load_more',
    );
  }

  @override
  List<MediaPost> mergeAndDedupePosts(
    List<MediaPost> current,
    List<MediaPost> incoming,
  ) {
    final byId = <String, MediaPost>{};
    for (final post in current) {
      byId[post.postId] = post;
    }
    for (final post in incoming) {
      byId[post.postId] = post;
    }

    final merged = byId.values.toList(growable: false)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return merged;
  }

  Future<TimelinePage> _fetchTimelinePage({
    required TimelineRequestType requestType,
    required String requestReason,
    String? sinceId,
    String? paginationToken,
  }) async {
    final session = await _authPersistenceService.getSession();
    _validateSession(session);
    final persistedSession = session!;

    final response = await _xApiClient.fetchUserTweets(
      accessToken: persistedSession.accessToken!,
      userId: persistedSession.userId,
      requestType: requestType,
      requestReason: requestReason,
      sinceId: sinceId,
      paginationToken: paginationToken,
    );
    final rawCount = response.data.length;
    final page = _adapter.fromApiResponse(
      response,
      sourceType: FeedMode.reposted,
      repostsOnly: true,
    );
    final imagePosts = _extractor.onlyImagePosts(page.posts);
    final timelinePage = TimelinePage(
      posts: imagePosts,
      newestId: page.newestId,
      nextCursor: page.nextCursor,
      resultCount: page.resultCount,
    );
    debugPrint(
      '[xviewer][flutter] Reposted fetch: reason=$requestReason type=${requestType.name} paginationToken=$paginationToken sinceId=$sinceId rawCount=$rawCount filteredImageCount=${imagePosts.length} nextToken=${response.nextToken} hasMore=${timelinePage.hasNextPage}',
    );
    return timelinePage;
  }

  Future<TimelinePage> _fetchNextUntilImagePosts({
    required String initialPaginationToken,
    required String requestReason,
  }) async {
    var paginationToken = initialPaginationToken;
    TimelinePage? lastPage;

    for (
      var attempt = 1;
      attempt <= _maxEmptyImagePagesPerLoadMore;
      attempt++
    ) {
      final page = await _fetchTimelinePage(
        requestType: TimelineRequestType.next,
        requestReason: '$requestReason#attempt$attempt',
        paginationToken: paginationToken,
      );
      lastPage = page;

      debugPrint(
        '[xviewer][flutter] Reposted loadMore scan: attempt=$attempt requestPaginationToken=$paginationToken rawResultCount=${page.resultCount} filteredImageCount=${page.posts.length} nextToken=${page.nextCursor} hasMore=${page.hasNextPage}',
      );

      if (page.posts.isNotEmpty) {
        return page;
      }
      if (!page.hasNextPage || (page.nextCursor ?? '').isEmpty) {
        debugPrint(
          '[xviewer][flutter] Reposted loadMore reached end while skipping empty image pages: attempt=$attempt nextToken=${page.nextCursor} hasMore=${page.hasNextPage}',
        );
        return page;
      }

      paginationToken = page.nextCursor!;
    }

    debugPrint(
      '[xviewer][flutter] Reposted loadMore stopped after max empty-image scans: attempts=$_maxEmptyImagePagesPerLoadMore finalNextToken=${lastPage?.nextCursor} finalHasMore=${lastPage?.hasNextPage}',
    );
    return lastPage ?? TimelinePage.empty;
  }

  void _validateSession(AuthSession? session) {
    if (session == null) {
      throw XApiException.unauthorized('No auth session found');
    }
    if (!session.hasAccessToken) {
      throw XApiException.unauthorized('Session did not contain an access token');
    }
    if (session.userId.isEmpty) {
      throw XApiException.unauthorized('Session did not contain a user id');
    }
  }
}
