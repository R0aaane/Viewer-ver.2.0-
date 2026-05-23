// ignore_for_file: file_names

part of 'detailImage.dart';

enum ReaderFitMode { vertical, horizontal, contain }

enum _DetailMenuAction { delete, deletePdfPage }

enum _TagSuggestionTab { recommended, recent, all }

enum _TagLayoutMode { chips, list }

class _TagSuggestionEntry {
  final Tag tag;
  final int usageCount;
  final bool isRecent;

  const _TagSuggestionEntry({
    required this.tag,
    required this.usageCount,
    required this.isRecent,
  });
}

class _PrefsKeys {
  static const String lastFolderRaw = 'prefs.lastFolderRaw';
  static const String fitMode = 'prefs.readerFitMode';
  static const String twoPage = 'prefs.readerTwoPage';

  static const String favorites = 'prefs.favorites';
  static const String ratingsJson = 'prefs.ratingsJson.v1';
  static const String detailRecentTags = 'prefs.detailRecentTags.v1';
}

class ImageDetailPage extends StatefulWidget {
  final MediaRepository repo;
  final TagService tagService;
  final List<MediaItem> items;
  final int initialIndex;
  final int? initialPdfPage;
  final String? initialPreloadItemId;
  final Future<int>? initialPageCountFuture;
  final Future<Uint8List>? initialReaderBytesFuture;

  const ImageDetailPage({
    super.key,
    required this.repo,
    required this.tagService,
    required this.items,
    required this.initialIndex,
    this.initialPdfPage,
    this.initialPreloadItemId,
    this.initialPageCountFuture,
    this.initialReaderBytesFuture,
  });

  @override
  State<ImageDetailPage> createState() => _ImageDetailPageState();
}
