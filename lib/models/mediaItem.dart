enum MediaKind { image, pdf }

class MediaItem {
  final String id; // Windows: full path / Android: document Uri
  final String displayName; // file name
  final DateTime? modified;
  final MediaKind kind;

  /// ★追加：このアイテムが属するフォルダ識別子
  /// Windows: 親ディレクトリパス
  /// Android: treeUri
  final String folderRaw;

  const MediaItem({
    required this.id,
    required this.displayName,
    required this.kind,
    required this.folderRaw,
    this.modified,
  });
}
