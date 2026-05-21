import 'feed_mode.dart';
import 'post_image.dart';

class MediaPost {
  const MediaPost({
    required this.postId,
    required this.authorName,
    required this.authorUsername,
    required this.originalAuthorName,
    required this.originalAuthorUsername,
    required this.text,
    required this.images,
    required this.originalPostUrl,
    required this.createdAt,
    required this.sourceType,
    this.reposterName,
    this.reposterUsername,
  });

  final String postId;
  final String authorName;
  final String authorUsername;
  final String originalAuthorName;
  final String originalAuthorUsername;
  final String? reposterName;
  final String? reposterUsername;
  final String text;
  final List<PostImage> images;
  final String originalPostUrl;
  final DateTime createdAt;
  final FeedMode sourceType;

  bool get hasImages => images.isNotEmpty;

  Map<String, dynamic> toJson() {
    return {
      'postId': postId,
      'authorName': authorName,
      'authorUsername': authorUsername,
      'originalAuthorName': originalAuthorName,
      'originalAuthorUsername': originalAuthorUsername,
      'reposterName': reposterName,
      'reposterUsername': reposterUsername,
      'text': text,
      'images': images.map((image) => image.toJson()).toList(growable: false),
      'originalPostUrl': originalPostUrl,
      'createdAt': createdAt.toIso8601String(),
      'sourceType': sourceType.name,
    };
  }

  factory MediaPost.fromJson(Map<String, dynamic> json) {
    return MediaPost(
      postId: json['postId'] as String? ?? '',
      authorName: json['authorName'] as String? ?? 'Unknown',
      authorUsername: json['authorUsername'] as String? ?? 'unknown_user',
      originalAuthorName:
          json['originalAuthorName'] as String? ??
          json['authorName'] as String? ??
          'Unknown',
      originalAuthorUsername:
          json['originalAuthorUsername'] as String? ??
          json['authorUsername'] as String? ??
          'unknown_user',
      reposterName: json['reposterName'] as String?,
      reposterUsername: json['reposterUsername'] as String?,
      text: json['text'] as String? ?? '',
      images: (json['images'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .map(PostImage.fromJson)
          .toList(growable: false),
      originalPostUrl: json['originalPostUrl'] as String? ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      sourceType: FeedMode.values.firstWhere(
        (mode) => mode.name == json['sourceType'],
        orElse: () => FeedMode.timeline,
      ),
    );
  }
}
