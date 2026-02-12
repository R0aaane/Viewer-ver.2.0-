import 'tag.dart';

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

  /// ★追加：タグ（カテゴリ付き）
  final List<Tag> tags;

  const MediaItem({
    required this.id,
    required this.displayName,
    required this.kind,
    required this.folderRaw,
    this.modified,
    this.tags = const [], // ← ここが重要（既存コード互換）
  });
}
