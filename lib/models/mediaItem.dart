enum MediaKind { image, pdf }

class MediaItem {
  final String id;            // Windows: full path
  final String displayName;   // file name
  final DateTime? modified;
  final MediaKind kind;

  const MediaItem({
    required this.id,
    required this.displayName,
    required this.kind,
    this.modified,
  });
}

