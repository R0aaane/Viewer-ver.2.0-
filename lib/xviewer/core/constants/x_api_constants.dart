abstract final class XApiConstants {
  static const primaryBaseUrl = 'https://api.x.com';
  static const fallbackBaseUrl = 'https://api.twitter.com';
  static const primaryV2BaseUrl = '$primaryBaseUrl/2';
  static const fallbackV2BaseUrl = '$fallbackBaseUrl/2';
  static const baseUrl = primaryV2BaseUrl;
  static const userByIdPath = '/users/{id}';
  static const userTweetsPath = '/users/{id}/tweets';
  static const reverseChronologicalTimelinePath =
      '/users/{id}/timelines/reverse_chronological';
  static const initialMaxResults = 20;
  static const newerMaxResults = 20;
  static const nextMaxResults = 20;
  static const timelineSyncCooldown = Duration(seconds: 120);
  static const excludeReplies = true;
  static const excludeRetweets = true;

  static const expansions = <String>[
    'attachments.media_keys',
    'author_id',
    'referenced_tweets.id',
    'referenced_tweets.id.author_id',
  ];

  static const tweetFields = <String>[
    'attachments',
    'author_id',
    'created_at',
    'referenced_tweets',
    'text',
  ];

  static const mediaFields = <String>[
    'media_key',
    'preview_image_url',
    'type',
    'url',
  ];

  static const userFields = <String>[
    'id',
    'name',
    'username',
  ];

  // TODO(api-usage): re-enable retweets if product requirements need them.
  static const defaultExclude = <String>[
    if (excludeReplies) 'replies',
    if (excludeRetweets) 'retweets',
  ];
}
