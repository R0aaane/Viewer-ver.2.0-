class PostImage {
  const PostImage({
    required this.mediaKey,
    required this.imageUrl,
    required this.width,
    required this.height,
  });

  final String mediaKey;
  final String imageUrl;
  final int width;
  final int height;

  Map<String, dynamic> toJson() {
    return {
      'mediaKey': mediaKey,
      'imageUrl': imageUrl,
      'width': width,
      'height': height,
    };
  }

  factory PostImage.fromJson(Map<String, dynamic> json) {
    return PostImage(
      mediaKey: json['mediaKey'] as String,
      imageUrl: json['imageUrl'] as String,
      width: json['width'] as int? ?? 0,
      height: json['height'] as int? ?? 0,
    );
  }
}
