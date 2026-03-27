import 'tag.dart';

enum MediaKind { image, pdf, folder }

class MediaItem {
  final String id; // Windowsはfull path / Android: document Uri
  final String displayName; // file name
  final DateTime? modified;
  final int? sizeBytes;
  final MediaKind kind;

  /// このアイテムが属するフォルダ識別子
  /// Windows: 親ディレクトリパス
  /// Android: treeUri
  final String folderRaw;

  /// タグ（カテゴリ付き）
  final List<Tag> tags;

  const MediaItem({
    required this.id,
    required this.displayName,
    required this.kind,
    required this.folderRaw,
    this.modified,
    this.sizeBytes,
    this.tags = const [],
  });
}
