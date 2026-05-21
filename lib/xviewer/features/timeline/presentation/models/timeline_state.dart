import '../../../../domain/models/feed_mode.dart';
import '../../../../domain/models/media_post.dart';

class FeedPageState {
  const FeedPageState({
    required this.items,
    required this.lastNewestId,
    required this.nextToken,
    required this.hasMore,
    required this.isRefreshing,
    required this.isLoadingMore,
    required this.lastSyncedAt,
    required this.lastUsedPaginationToken,
    required this.errorMessage,
    required this.hasFetched,
  });

  final List<MediaPost> items;
  final String? lastNewestId;
  final String? nextToken;
  final bool hasMore;
  final bool isRefreshing;
  final bool isLoadingMore;
  final DateTime? lastSyncedAt;
  final String? lastUsedPaginationToken;
  final String? errorMessage;
  final bool hasFetched;

  FeedPageState copyWith({
    List<MediaPost>? items,
    String? lastNewestId,
    bool clearLastNewestId = false,
    String? nextToken,
    bool clearNextToken = false,
    bool? hasMore,
    bool? isRefreshing,
    bool? isLoadingMore,
    DateTime? lastSyncedAt,
    bool clearLastSyncedAt = false,
    String? lastUsedPaginationToken,
    bool clearLastUsedPaginationToken = false,
    String? errorMessage,
    bool clearErrorMessage = false,
    bool? hasFetched,
  }) {
    return FeedPageState(
      items: items ?? this.items,
      lastNewestId: clearLastNewestId
          ? null
          : lastNewestId ?? this.lastNewestId,
      nextToken: clearNextToken ? null : nextToken ?? this.nextToken,
      hasMore: hasMore ?? this.hasMore,
      isRefreshing: isRefreshing ?? this.isRefreshing,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      lastSyncedAt: clearLastSyncedAt
          ? null
          : lastSyncedAt ?? this.lastSyncedAt,
      lastUsedPaginationToken: clearLastUsedPaginationToken
          ? null
          : lastUsedPaginationToken ?? this.lastUsedPaginationToken,
      errorMessage: clearErrorMessage ? null : errorMessage ?? this.errorMessage,
      hasFetched: hasFetched ?? this.hasFetched,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'items': items.map((item) => item.toJson()).toList(growable: false),
      'lastNewestId': lastNewestId,
      'nextToken': nextToken,
      'hasMore': hasMore,
      'isRefreshing': isRefreshing,
      'isLoadingMore': isLoadingMore,
      'lastSyncedAt': lastSyncedAt?.toIso8601String(),
      'lastUsedPaginationToken': lastUsedPaginationToken,
      'errorMessage': errorMessage,
      'hasFetched': hasFetched,
    };
  }

  factory FeedPageState.fromJson(Map<String, dynamic> json) {
    return FeedPageState(
      items: (json['items'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .map(MediaPost.fromJson)
          .toList(growable: false),
      lastNewestId: json['lastNewestId'] as String?,
      nextToken: json['nextToken'] as String?,
      hasMore: json['hasMore'] as bool? ?? false,
      isRefreshing: false,
      isLoadingMore: false,
      lastSyncedAt: json['lastSyncedAt'] == null
          ? null
          : DateTime.tryParse(json['lastSyncedAt'] as String),
      lastUsedPaginationToken: json['lastUsedPaginationToken'] as String?,
      errorMessage: json['errorMessage'] as String?,
      hasFetched: json['hasFetched'] as bool? ?? false,
    );
  }

  static const empty = FeedPageState(
    items: <MediaPost>[],
    lastNewestId: null,
    nextToken: null,
    hasMore: false,
    isRefreshing: false,
    isLoadingMore: false,
    lastSyncedAt: null,
    lastUsedPaginationToken: null,
    errorMessage: null,
    hasFetched: false,
  );
}

class TimelineState {
  const TimelineState({
    required this.selectedMode,
    required this.reposted,
    required this.timeline,
  });

  final FeedMode selectedMode;
  final FeedPageState reposted;
  final FeedPageState timeline;

  FeedPageState feedStateFor(FeedMode mode) {
    switch (mode) {
      case FeedMode.reposted:
        return reposted;
      case FeedMode.timeline:
        return timeline;
      case FeedMode.liked:
        return FeedPageState.empty;
    }
  }

  TimelineState copyWith({
    FeedMode? selectedMode,
    FeedPageState? reposted,
    FeedPageState? timeline,
  }) {
    return TimelineState(
      selectedMode: selectedMode ?? this.selectedMode,
      reposted: reposted ?? this.reposted,
      timeline: timeline ?? this.timeline,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'selectedMode': selectedMode.name,
      'reposted': reposted.toJson(),
      'timeline': timeline.toJson(),
    };
  }

  factory TimelineState.fromJson(Map<String, dynamic> json) {
    if (json.containsKey('items')) {
      return TimelineState(
        selectedMode: FeedMode.reposted,
        reposted: FeedPageState.empty,
        timeline: FeedPageState.fromJson(json),
      );
    }
    final repostedJson = json['reposted'];
    final timelineJson = json['timeline'];
    return TimelineState(
      selectedMode: FeedMode.values.firstWhere(
        (mode) => mode.name == json['selectedMode'],
        orElse: () => FeedMode.reposted,
      ),
      reposted: repostedJson is Map
          ? FeedPageState.fromJson(Map<String, dynamic>.from(repostedJson))
          : FeedPageState.empty,
      timeline: timelineJson is Map
          ? FeedPageState.fromJson(Map<String, dynamic>.from(timelineJson))
          : FeedPageState.empty,
    );
  }

  static const empty = TimelineState(
    selectedMode: FeedMode.reposted,
    reposted: FeedPageState.empty,
    timeline: FeedPageState.empty,
  );
}
