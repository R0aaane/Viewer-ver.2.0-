import 'dart:typed_data';
import '../models/folder.dart';
import '../models/mediaItem.dart';

class ThumbPair {
  final Uint8List front;
  final Uint8List? back;
  const ThumbPair({required this.front, this.back});
}

abstract class MediaRepository {
  Future<FolderHandle?> pickFolder();
  Future<List<MediaItem>> listMedia(FolderHandle folder);

  /// 一覧用サムネ
  Future<ThumbPair> readThumbPair(MediaItem item, {int maxWidth = 360});

  /// 元データ（画像用）
  Future<Uint8List> readBytes(MediaItem item);

  // ---- 追加 ----

  /// PDF: 総ページ数 / 画像: 1
  Future<int> getPageCount(MediaItem item);

  /// page(1-based) を画像として返す
  /// 画像は page 無視でOK
  Future<Uint8List> renderPageBytes(
    MediaItem item,
    int page, {
    int maxWidth = 1600,
  });

  /// ファイル名変更（displayName のみ変更。id(uri/path)は基本維持）
  Future<MediaItem> rename(MediaItem item, String newDisplayName);

}
