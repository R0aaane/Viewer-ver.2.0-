import 'package:flutter/foundation.dart';

import '../../core/constants/x_api_constants.dart';
import '../../domain/models/feed_mode.dart';
import '../../core/errors/x_api_exception.dart';
import '../../domain/models/auth_session.dart';
import '../../domain/models/media_post.dart';
import '../../domain/models/timeline_page.dart';
import '../../domain/repositories/timeline_repository.dart';
import '../../services/auth_persistence_service.dart';
import '../../services/timeline_media_extractor.dart';
import '../../services/x_timeline_request_builder.dart';
import '../adapters/x_timeline_adapter.dart';
import '../datasources/x_api_client.dart';

class TimelineRepositoryImpl implements TimelineRepository {
  TimelineRepositoryImpl(
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
    return _fetchTimelinePage(
      requestType: TimelineRequestType.next,
      requestReason: 'load_more',
      paginationToken: paginationToken,
    );
  }

  @override
  bool shouldSync({DateTime? lastSyncedAt}) {
    if (lastSyncedAt == null) {
      return true;
    }

    final elapsed = DateTime.now().difference(lastSyncedAt);
    final shouldSync = elapsed >= XApiConstants.timelineSyncCooldown;
    debugPrint(
      '[xviewer][flutter] Timeline sync decision: shouldSync=$shouldSync lastSyncedAt=$lastSyncedAt elapsedSeconds=${elapsed.inSeconds}',
    );
    return shouldSync;
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

    final response = await _xApiClient.fetchHomeTimeline(
      accessToken: persistedSession.accessToken!,
      userId: persistedSession.userId,
      requestType: requestType,
      requestReason: requestReason,
      sinceId: sinceId,
      paginationToken: paginationToken,
    );
    final page = _adapter.fromApiResponse(
      response,
      sourceType: FeedMode.timeline,
    );
    return TimelinePage(
      posts: _extractor.onlyImagePosts(page.posts),
      newestId: page.newestId,
      nextCursor: page.nextCursor,
      resultCount: page.resultCount,
    );
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
