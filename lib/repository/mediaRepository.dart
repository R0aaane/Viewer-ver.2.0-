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

  // アプリ専用保管庫フォルダ（必ず書き込み可）を返す
  Future<FolderHandle> getAppLibraryFolder();

  /// フォルダ内のメディア一覧を取得。
  /// onProgress(processed,total) を随時呼ぶ（total が不明なら 0）。
  Future<List<MediaItem>> listMedia(
    FolderHandle folder, {
    void Function(int processed, int total)? onProgress,
  });

  // 外部から選んだ画像/PDFを folder に取り込む（コピー保存）
  Future<int> importIntoFolder(FolderHandle folder);

  /// 一覧用サムネ
  Future<ThumbPair> readThumbPair(MediaItem item, {int maxWidth = 360});

  /// 元データ（画像用）
  Future<Uint8List> readBytes(MediaItem item);

  /// PDF: 総ページ数 / 画像: 1
  Future<int> getPageCount(MediaItem item);

  /// page(1-based) を画像として返す
  /// 画像は page 無視で大丈夫
  Future<Uint8List> renderPageBytes(
    MediaItem item,
    int page, {
    int maxWidth = 1600,
  });

  // ファイル名変更（displayName のみ変更。id(uri/path)は基本維持、市内と崩れる）
  Future<MediaItem> rename(MediaItem item, String newDisplayName);
}
