import 'dart:io' show File;

import 'package:path/path.dart' as p;

import '../database/pdf_export_service.dart';
import '../models/mediaItem.dart';
import '../models/tag.dart';
import '../repository/mediaRepository.dart';
import 'import_tag_rule_service.dart';

class ImportPdfConversionResult {
  final List<MediaItem> items;
  final List<String> cleanupPaths;
  final bool convertedToPdf;
  final int imageCount;
  final String sourceFolderRaw;
  final String sourceFolderLabel;
  final PdfExportResult? generatedPdf;

  const ImportPdfConversionResult({
    required this.items,
    required this.cleanupPaths,
    required this.convertedToPdf,
    required this.imageCount,
    required this.sourceFolderRaw,
    required this.sourceFolderLabel,
    this.generatedPdf,
  });
}

class ImportPdfConversionService {
  static bool canConvertItemsToPdf(List<MediaItem> items) {
    final mediaItems = items
        .where((item) => item.kind != MediaKind.folder)
        .toList(growable: false);
    if (mediaItems.length < 2) {
      return false;
    }
    return mediaItems.every((item) => item.kind == MediaKind.image);
  }

  static String suggestPdfBaseName(
    List<MediaItem> items, {
    String? preferredName,
  }) {
    final preferred = preferredName?.trim();
    if (preferred != null && preferred.isNotEmpty) {
      return PdfExportService.sanitizePdfName(preferred);
    }

    final commonFolderRaw = _commonFolderRaw(items);
    if (commonFolderRaw.isNotEmpty &&
        !commonFolderRaw.startsWith('content://')) {
      final normalized = commonFolderRaw.replaceAll('\\', '/');
      final parts = normalized
          .split('/')
          .map((part) => part.trim())
          .where((part) => part.isNotEmpty)
          .toList(growable: false);
      if (parts.isNotEmpty) {
        return PdfExportService.sanitizePdfName(parts.last);
      }
    }

    final firstName = items.isEmpty ? '' : items.first.displayName.trim();
    if (firstName.isNotEmpty) {
      final stem = p.basenameWithoutExtension(firstName).trim();
      if (stem.isNotEmpty) {
        return PdfExportService.sanitizePdfName(stem);
      }
    }

    return 'import_${DateTime.now().millisecondsSinceEpoch}';
  }

  static Future<ImportPdfConversionResult> prepareForImport({
    required MediaRepository repo,
    required List<MediaItem> items,
    bool convertToPdf = false,
    String? preferredName,
    String? libraryRootRaw,
    void Function(int done, int total)? onPdfProgress,
  }) async {
    final imageItems = _stableImageItems(items);
    final sourceFolderRaw = _commonFolderRaw(items);
    final sourceFolderLabel = suggestPdfBaseName(
      imageItems.isNotEmpty ? imageItems : items,
      preferredName: preferredName,
    );

    if (!convertToPdf || !canConvertItemsToPdf(items)) {
      return ImportPdfConversionResult(
        items: items,
        cleanupPaths: const <String>[],
        convertedToPdf: false,
        imageCount: imageItems.length,
        sourceFolderRaw: sourceFolderRaw,
        sourceFolderLabel: sourceFolderLabel,
      );
    }

    final created = await PdfExportService.exportFolderToTemporaryPdf(
      repo,
      imageItems,
      sourceFolderLabel,
      onProgress: onPdfProgress,
    );
    final generatedItem = await _buildGeneratedPdfItem(created);
    if (generatedItem == null) {
      throw Exception('Failed to prepare the generated PDF for import.');
    }

    final inferred = ImportTagRuleService.inferForGeneratedPdf(
      sourceFolderRaw: sourceFolderRaw,
      sourceFolderLabel: sourceFolderLabel,
      generatedFileName: created.savedName,
      libraryRootRaw: libraryRootRaw,
    );
    final taggedItem = MediaItem(
      id: generatedItem.id,
      displayName: generatedItem.displayName,
      kind: generatedItem.kind,
      folderRaw: generatedItem.folderRaw,
      modified: generatedItem.modified,
      sizeBytes: generatedItem.sizeBytes,
      tags: _mergeDistinctTags(inferred.tags),
    );

    return ImportPdfConversionResult(
      items: <MediaItem>[taggedItem],
      cleanupPaths: <String>[
        if (created.savedPath?.trim().isNotEmpty ?? false)
          created.savedPath!.trim(),
      ],
      convertedToPdf: true,
      imageCount: imageItems.length,
      sourceFolderRaw: sourceFolderRaw,
      sourceFolderLabel: sourceFolderLabel,
      generatedPdf: created,
    );
  }

  static List<MediaItem> _stableImageItems(List<MediaItem> items) {
    final images = items
        .where((item) => item.kind == MediaKind.image)
        .toList(growable: true);
    images.sort((a, b) {
      final nameCompare = a.displayName.toLowerCase().compareTo(
        b.displayName.toLowerCase(),
      );
      if (nameCompare != 0) {
        return nameCompare;
      }
      final folderCompare = a.folderRaw.toLowerCase().compareTo(
        b.folderRaw.toLowerCase(),
      );
      if (folderCompare != 0) {
        return folderCompare;
      }
      return a.id.toLowerCase().compareTo(b.id.toLowerCase());
    });
    return images.toList(growable: false);
  }

  static String _commonFolderRaw(List<MediaItem> items) {
    final candidates = items
        .map((item) => item.folderRaw.trim())
        .where((raw) => raw.isNotEmpty)
        .toList(growable: false);
    if (candidates.isEmpty) {
      return '';
    }
    final first = candidates.first;
    final allSame = candidates.every((raw) => raw == first);
    if (allSame) {
      return first;
    }
    return first;
  }

  static Future<MediaItem?> _buildGeneratedPdfItem(
    PdfExportResult created,
  ) async {
    if ((created.savedPath?.trim().isNotEmpty ?? false)) {
      final path = created.savedPath!.trim();
      try {
        final file = File(path);
        final stat = await file.stat();
        return MediaItem(
          id: file.path,
          displayName: created.savedName,
          kind: MediaKind.pdf,
          folderRaw: created.savedFolderRaw ?? file.parent.path,
          modified: stat.modified,
          sizeBytes: stat.size,
          tags: const <Tag>[],
        );
      } catch (_) {}
    }

    if ((created.savedUri?.trim().isNotEmpty ?? false)) {
      return MediaItem(
        id: created.savedUri!.trim(),
        displayName: created.savedName,
        kind: MediaKind.pdf,
        folderRaw: (created.savedFolderRaw ?? created.savedUri!).trim(),
        modified: DateTime.now(),
        tags: const <Tag>[],
      );
    }

    return null;
  }

  static List<Tag> _mergeDistinctTags(Iterable<Tag> tags) {
    final out = <Tag>[];
    final seen = <String>{};
    for (final tag in tags) {
      final name = tag.name.trim();
      if (name.isEmpty) {
        continue;
      }
      final key = '${tag.category.name}\u0000${name.toLowerCase()}';
      if (!seen.add(key)) {
        continue;
      }
      out.add(Tag(name: name, category: tag.category));
    }
    return out;
  }
}
