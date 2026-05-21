import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/x_api_constants.dart';
import '../../../../core/errors/error_message_formatter.dart';
import '../../../../data/adapters/x_timeline_adapter.dart';
import '../../../../data/datasources/x_api_client.dart';
import '../../../../data/mappers/x_timeline_includes_mapper.dart';
import '../../../../data/repositories/reposted_image_repository_impl.dart';
import '../../../../data/repositories/timeline_repository_impl.dart';
import '../../../../domain/models/auth_session.dart';
import '../../../../domain/models/feed_mode.dart';
import '../../../../domain/models/timeline_page.dart';
import '../../../../domain/repositories/reposted_image_repository.dart';
import '../../../../domain/repositories/timeline_repository.dart';
import '../../../../services/timeline_cache_service.dart';
import '../../../../services/timeline_media_extractor.dart';
import '../../../../services/x_timeline_request_builder.dart';
import '../../../auth/presentation/providers/auth_controller.dart';
import '../models/timeline_state.dart';

final xApiDioProvider = Provider<Dio>(
  (ref) {
    final dio = Dio(
      BaseOptions(
        baseUrl: XApiConstants.baseUrl,
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 20),
      ),
    );
    if (kDebugMode) {
      dio.interceptors.add(
        LogInterceptor(
          requestBody: false,
          responseBody: false,
        ),
      );
    }
    return dio;
  },
);

final xTimelineRequestBuilderProvider = Provider<XTimelineRequestBuilder>(
  (ref) => const XTimelineRequestBuilder(),
);

final xTimelineIncludesMapperProvider = Provider<XTimelineIncludesMapper>(
  (ref) => const XTimelineIncludesMapper(),
);

final xApiClientProvider = Provider<XApiClient>((ref) {
  return XApiClient(
    dio: ref.watch(xApiDioProvider),
    requestBuilder: ref.watch(xTimelineRequestBuilderProvider),
  );
});

final xTimelineAdapterProvider = Provider<XTimelineAdapter>(
  (ref) => XTimelineAdapter(ref.watch(xTimelineIncludesMapperProvider)),
);

final timelineMediaExtractorProvider = Provider<TimelineMediaExtractor>(
  (ref) => TimelineMediaExtractor(),
);

final timelineCacheServiceProvider = Provider<TimelineCacheService>(
  (ref) => const TimelineCacheService(),
);

final timelineRepositoryProvider = Provider<TimelineRepository>((ref) {
  return TimelineRepositoryImpl(
    ref.watch(xApiClientProvider),
    ref.watch(xTimelineAdapterProvider),
    ref.watch(timelineMediaExtractorProvider),
    ref.watch(authPersistenceServiceProvider),
  );
});

final repostedImageRepositoryProvider = Provider<RepostedImageRepository>((
  ref,
) {
  return RepostedImageRepositoryImpl(
    ref.watch(xApiClientProvider),
    ref.watch(xTimelineAdapterProvider),
    ref.watch(timelineMediaExtractorProvider),
    ref.watch(authPersistenceServiceProvider),
  );
});

final timelineControllerProvider =
    AsyncNotifierProvider<TimelineController, TimelineState>(
      TimelineController.new,
    );

class TimelineController extends AsyncNotifier<TimelineState> {
  @override
  Future<TimelineState> build() async {
    final session = await _getSession();
    if (session == null || session.userId.isEmpty) {
      return TimelineState.empty;
    }

    final cached = await ref.read(timelineCacheServiceProvider).read(
      session.userId,
    );
    if (cached != null) {
      if (cached.reposted.hasFetched) {
        return cached.copyWith(selectedMode: FeedMode.reposted);
      }

      final initialPage = await ref
          .read(repostedImageRepositoryProvider)
          .fetchInitial();
      final hydratedState = cached.copyWith(
        selectedMode: FeedMode.reposted,
        reposted: _toFeedState(initialPage),
      );
      await _persistState(hydratedState);
      return hydratedState;
    }

    final initialPage = await ref
        .read(repostedImageRepositoryProvider)
        .fetchInitial();
    final initialState = TimelineState(
      selectedMode: FeedMode.reposted,
      reposted: _toFeedState(initialPage),
      timeline: FeedPageState.empty,
    );
    await _persistState(initialState);
    return initialState;
  }

  void selectMode(FeedMode mode) {
    final current = state.valueOrNull;
    if (current == null || current.selectedMode == mode) {
      return;
    }

    state = AsyncData(current.copyWith(selectedMode: mode));
  }

  Future<void> refreshSelected() async {
    final current = state.valueOrNull;
    if (current == null) {
      return;
    }

    await refreshMode(current.selectedMode);
  }

  Future<void> refreshMode(FeedMode mode) async {
    switch (mode) {
      case FeedMode.reposted:
        await _refreshRepostedFeed();
        return;
      case FeedMode.timeline:
        await _refreshTimelineFeed();
        return;
      case FeedMode.liked:
        return;
    }
  }

  Future<void> loadNextPage() async {
    final current = state.valueOrNull;
    if (current == null) {
      return;
    }

    final mode = current.selectedMode;
    final feed = current.feedStateFor(mode);
    final nextToken = feed.nextToken;
    if (feed.isLoadingMore ||
        nextToken == null ||
        nextToken.isEmpty ||
        !feed.hasMore) {
      return;
    }
    if (feed.lastUsedPaginationToken == nextToken) {
      debugPrint(
        '[xviewer][flutter] Feed loadMore skipped: mode=${mode.name} duplicate pagination token token=$nextToken',
      );
      return;
    }

    _updateFeed(
      mode,
      feed.copyWith(
        isLoadingMore: true,
        lastUsedPaginationToken: nextToken,
        clearErrorMessage: true,
      ),
    );

    try {
      final nextPage = switch (mode) {
        FeedMode.reposted => await ref
            .read(repostedImageRepositoryProvider)
            .fetchNext(paginationToken: nextToken),
        FeedMode.timeline => await ref
            .read(timelineRepositoryProvider)
            .fetchNext(paginationToken: nextToken),
        FeedMode.liked => TimelinePage.empty,
      };
      if (mode == FeedMode.liked) {
        return;
      }

      final mergedItems = switch (mode) {
        FeedMode.reposted => ref
            .read(repostedImageRepositoryProvider)
            .mergeAndDedupePosts(feed.items, nextPage.posts),
        FeedMode.timeline => ref
            .read(timelineRepositoryProvider)
            .mergeAndDedupePosts(feed.items, nextPage.posts),
        FeedMode.liked => feed.items,
      };
      final nextFeed = feed.copyWith(
        items: mergedItems,
        lastNewestId: feed.lastNewestId ?? nextPage.newestId,
        nextToken: nextPage.nextCursor,
        clearNextToken: (nextPage.nextCursor ?? '').isEmpty,
        hasMore: nextPage.hasNextPage,
        isLoadingMore: false,
        lastSyncedAt: DateTime.now(),
        clearErrorMessage: true,
        hasFetched: true,
      );
      debugPrint(
        '[xviewer][flutter] Feed loadMore completed: mode=${mode.name} requestToken=$nextToken receivedPosts=${nextPage.posts.length} nextToken=${nextPage.nextCursor} hasMore=${nextPage.hasNextPage} totalItems=${nextFeed.items.length}',
      );
      _updateFeed(mode, nextFeed);
      await _persistCurrentState();
    } catch (error) {
      _updateFeed(
        mode,
        feed.copyWith(
          isLoadingMore: false,
          errorMessage: formatErrorMessage(error),
        ),
      );
    }
  }

  Future<void> _refreshRepostedFeed() async {
    final current = state.valueOrNull ?? TimelineState.empty;
    final feed = current.reposted;
    if (feed.isRefreshing) {
      return;
    }

    _updateFeed(
      FeedMode.reposted,
      feed.copyWith(
        isRefreshing: true,
        clearErrorMessage: true,
      ),
    );

    try {
      final TimelinePage page;
      if (!feed.hasFetched || feed.items.isEmpty) {
        page = await ref.read(repostedImageRepositoryProvider).fetchInitial();
      } else {
        page = await ref.read(repostedImageRepositoryProvider).fetchNewer(
          sinceId: feed.lastNewestId,
          requestReason: 'manual_refresh',
        );
      }

      final mergedItems = !feed.hasFetched || feed.items.isEmpty
          ? page.posts
          : ref
                .read(repostedImageRepositoryProvider)
                .mergeAndDedupePosts(page.posts, feed.items);
      final nextFeed = feed.copyWith(
        items: mergedItems,
        lastNewestId: page.newestId ?? feed.lastNewestId,
        nextToken: page.nextCursor,
        clearNextToken: (page.nextCursor ?? '').isEmpty,
        hasMore: page.hasNextPage,
        isRefreshing: false,
        lastSyncedAt: DateTime.now(),
        clearErrorMessage: true,
        hasFetched: true,
      );
      _updateFeed(FeedMode.reposted, nextFeed);
      await _persistCurrentState();
    } catch (error) {
      _updateFeed(
        FeedMode.reposted,
        feed.copyWith(
          isRefreshing: false,
          errorMessage: formatErrorMessage(error),
          hasFetched: feed.hasFetched,
        ),
      );
    }
  }

  Future<void> _refreshTimelineFeed() async {
    final current = state.valueOrNull ?? TimelineState.empty;
    final feed = current.timeline;
    if (feed.isRefreshing) {
      return;
    }

    // TODO(api-usage): keep timeline requests user-triggered only.
    _updateFeed(
      FeedMode.timeline,
      feed.copyWith(
        isRefreshing: true,
        clearErrorMessage: true,
      ),
    );

    try {
      final TimelinePage page;
      if (!feed.hasFetched || feed.items.isEmpty) {
        page = await ref.read(timelineRepositoryProvider).fetchInitial();
      } else {
        page = await ref.read(timelineRepositoryProvider).fetchNewer(
          sinceId: feed.lastNewestId,
          requestReason: 'manual_refresh',
        );
      }

      final mergedItems = !feed.hasFetched || feed.items.isEmpty
          ? page.posts
          : ref.read(timelineRepositoryProvider).mergeAndDedupePosts(
                page.posts,
                feed.items,
              );
      final nextFeed = feed.copyWith(
        items: mergedItems,
        lastNewestId: page.newestId ?? feed.lastNewestId,
        nextToken: page.nextCursor,
        clearNextToken: (page.nextCursor ?? '').isEmpty,
        hasMore: page.hasNextPage,
        isRefreshing: false,
        lastSyncedAt: DateTime.now(),
        clearErrorMessage: true,
        hasFetched: true,
      );
      _updateFeed(FeedMode.timeline, nextFeed);
      await _persistCurrentState();
    } catch (error) {
      _updateFeed(
        FeedMode.timeline,
        feed.copyWith(
          isRefreshing: false,
          errorMessage: formatErrorMessage(error),
          hasFetched: feed.hasFetched,
        ),
      );
    }
  }

  FeedPageState _toFeedState(TimelinePage page) {
    return FeedPageState(
      items: page.posts,
      lastNewestId: page.newestId,
      nextToken: page.nextCursor,
      hasMore: page.hasNextPage,
      isRefreshing: false,
      isLoadingMore: false,
      lastSyncedAt: DateTime.now(),
      lastUsedPaginationToken: null,
      errorMessage: null,
      hasFetched: true,
    );
  }

  void _updateFeed(FeedMode mode, FeedPageState nextFeed) {
    final current = state.valueOrNull ?? TimelineState.empty;
    final nextState = switch (mode) {
      FeedMode.reposted => current.copyWith(reposted: nextFeed),
      FeedMode.timeline => current.copyWith(timeline: nextFeed),
      FeedMode.liked => current,
    };
    state = AsyncData(nextState);
  }

  Future<AuthSession?> _getSession() {
    return ref.read(authPersistenceServiceProvider).getSession();
  }

  Future<void> _persistCurrentState() async {
    final current = state.valueOrNull;
    if (current == null) {
      return;
    }
    await _persistState(current);
  }

  Future<void> _persistState(TimelineState timelineState) async {
    final session = await _getSession();
    if (session == null || session.userId.isEmpty) {
      return;
    }
    await ref
        .read(timelineCacheServiceProvider)
        .write(userId: session.userId, state: timelineState);
  }
}
