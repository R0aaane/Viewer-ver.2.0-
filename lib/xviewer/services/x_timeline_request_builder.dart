import '../core/constants/x_api_constants.dart';

enum TimelineRequestType { initial, newer, next }

class XTimelineRequestBuilder {
  const XTimelineRequestBuilder();

  Map<String, dynamic> buildHomeTimeline({
    required TimelineRequestType type,
    String? sinceId,
    String? paginationToken,
  }) {
    final maxResults = switch (type) {
      TimelineRequestType.initial => XApiConstants.initialMaxResults,
      TimelineRequestType.newer => XApiConstants.newerMaxResults,
      TimelineRequestType.next => XApiConstants.nextMaxResults,
    };

    return {
      'max_results': maxResults,
      'expansions': XApiConstants.expansions.join(','),
      'tweet.fields': XApiConstants.tweetFields.join(','),
      'media.fields': XApiConstants.mediaFields.join(','),
      'user.fields': XApiConstants.userFields.join(','),
      if (XApiConstants.defaultExclude.isNotEmpty)
        'exclude': XApiConstants.defaultExclude.join(','),
      if ((sinceId ?? '').isNotEmpty) 'since_id': sinceId,
      if ((paginationToken ?? '').isNotEmpty)
        'pagination_token': paginationToken,
    };
  }

  Map<String, dynamic> buildUserTweets({
    required TimelineRequestType type,
    String? sinceId,
    String? paginationToken,
  }) {
    final parameters = buildHomeTimeline(
      type: type,
      sinceId: sinceId,
      paginationToken: paginationToken,
    );
    parameters.remove('exclude');
    return parameters;
  }
}
