import 'dart:typed_data';
import '../models/folder.dart';
import '../models/mediaItem.dart';

class ThumbPair {
  final Uint8List front;       // 表紙
  final Uint8List? back;       // 背後（PDFは中間ページ、画像は任意）
  const ThumbPair({required this.front, this.back});
}

abstract class MediaRepository {
  Future<FolderHandle?> pickFolder();
  Future<List<MediaItem>> listMedia(FolderHandle folder);

  /// 一覧用サムネ（表紙＋背後）
  Future<ThumbPair> readThumbPair(MediaItem item, {int maxWidth = 360});

  /// 詳細/拡大用（元データ）
  Future<Uint8List> readBytes(MediaItem item);
}