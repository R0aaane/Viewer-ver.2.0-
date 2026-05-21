import 'save_location_type.dart';

class SavedMediaRecord {
  const SavedMediaRecord({
    required this.recordId,
    required this.postId,
    required this.mediaKey,
    required this.authorName,
    required this.authorUsername,
    required this.text,
    required this.imageUrl,
    required this.sourceImageUrl,
    required this.localSavedPath,
    required this.previewFilePath,
    required this.originalPostUrl,
    required this.createdAt,
    required this.savedAt,
    required this.saveLocationType,
    this.favorite = false,
    this.tags = const <String>[],
    this.galleryContentUri,
    this.galleryDisplayName,
  });

  final String recordId;
  final String postId;
  final String mediaKey;
  final String authorName;
  final String authorUsername;
  final String text;
  final String imageUrl;
  final String sourceImageUrl;
  final String localSavedPath;
  final String previewFilePath;
  final String originalPostUrl;
  final DateTime createdAt;
  final DateTime savedAt;
  final SaveLocationType saveLocationType;
  final bool favorite;
  final List<String> tags;
  final String? galleryContentUri;
  final String? galleryDisplayName;

  SavedMediaRecord copyWith({
    String? recordId,
    String? postId,
    String? mediaKey,
    String? authorName,
    String? authorUsername,
    String? text,
    String? imageUrl,
    String? sourceImageUrl,
    String? localSavedPath,
    String? previewFilePath,
    String? originalPostUrl,
    DateTime? createdAt,
    DateTime? savedAt,
    SaveLocationType? saveLocationType,
    bool? favorite,
    List<String>? tags,
    String? galleryContentUri,
    String? galleryDisplayName,
  }) {
    return SavedMediaRecord(
      recordId: recordId ?? this.recordId,
      postId: postId ?? this.postId,
      mediaKey: mediaKey ?? this.mediaKey,
      authorName: authorName ?? this.authorName,
      authorUsername: authorUsername ?? this.authorUsername,
      text: text ?? this.text,
      imageUrl: imageUrl ?? this.imageUrl,
      sourceImageUrl: sourceImageUrl ?? this.sourceImageUrl,
      localSavedPath: localSavedPath ?? this.localSavedPath,
      previewFilePath: previewFilePath ?? this.previewFilePath,
      originalPostUrl: originalPostUrl ?? this.originalPostUrl,
      createdAt: createdAt ?? this.createdAt,
      savedAt: savedAt ?? this.savedAt,
      saveLocationType: saveLocationType ?? this.saveLocationType,
      favorite: favorite ?? this.favorite,
      tags: List.unmodifiable(tags ?? this.tags),
      galleryContentUri: galleryContentUri ?? this.galleryContentUri,
      galleryDisplayName: galleryDisplayName ?? this.galleryDisplayName,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'recordId': recordId,
      'postId': postId,
      'mediaKey': mediaKey,
      'authorName': authorName,
      'authorUsername': authorUsername,
      'text': text,
      'imageUrl': imageUrl,
      'sourceImageUrl': sourceImageUrl,
      'localSavedPath': localSavedPath,
      'previewFilePath': previewFilePath,
      'originalPostUrl': originalPostUrl,
      'createdAt': createdAt.toIso8601String(),
      'savedAt': savedAt.toIso8601String(),
      'saveLocationType': saveLocationType.name,
      'favorite': favorite,
      'tags': tags,
      'galleryContentUri': galleryContentUri,
      'galleryDisplayName': galleryDisplayName,
    };
  }

  factory SavedMediaRecord.fromJson(Map<String, dynamic> json) {
    return SavedMediaRecord(
      recordId: json['recordId'] as String,
      postId: json['postId'] as String,
      mediaKey: json['mediaKey'] as String,
      authorName: json['authorName'] as String,
      authorUsername: json['authorUsername'] as String,
      text: json['text'] as String? ?? '',
      imageUrl: json['imageUrl'] as String,
      sourceImageUrl:
          json['sourceImageUrl'] as String? ?? json['imageUrl'] as String,
      localSavedPath: json['localSavedPath'] as String,
      previewFilePath:
          json['previewFilePath'] as String? ??
          json['localSavedPath'] as String,
      originalPostUrl: json['originalPostUrl'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      savedAt: DateTime.parse(json['savedAt'] as String),
      saveLocationType: SaveLocationType.values.byName(
        json['saveLocationType'] as String? ?? SaveLocationType.appPrivate.name,
      ),
      favorite: json['favorite'] as bool? ?? false,
      tags: _parseTags(json['tags']),
      galleryContentUri: json['galleryContentUri'] as String?,
      galleryDisplayName: json['galleryDisplayName'] as String?,
    );
  }

  static List<String> _parseTags(Object? rawTags) {
    if (rawTags is! List) {
      return const <String>[];
    }

    final normalized = rawTags
        .map((tag) => tag?.toString().trim() ?? '')
        .where((tag) => tag.isNotEmpty)
        .map((tag) => tag.toLowerCase())
        .toSet()
        .toList()
      ..sort();
    return List.unmodifiable(normalized);
  }
}
