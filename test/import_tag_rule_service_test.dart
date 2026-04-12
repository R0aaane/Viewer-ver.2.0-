import 'package:flutter_test/flutter_test.dart';

import 'package:pdf_viewer/models/tag.dart';
import 'package:pdf_viewer/repository/mediaRepository.dart';
import 'package:pdf_viewer/services/import_tag_rule_service.dart';

void main() {
  group('ImportTagRuleService', () {
    test('does not infer hitomi series from generated pdf file names alone', () {
      final inferred = ImportTagRuleService.inferForGeneratedPdf(
        sourceFolderRaw:
            r'C:\library\hitomi\[12345] ArtistName\[20241105] [3114110] Sample Title',
        sourceFolderLabel: '[20241105] [3114110] Sample Title',
        generatedFileName: '[20241105] [3114110] Sample Title.pdf',
        libraryRootRaw: r'C:\library',
      );

      expect(
        inferred.tags.any(
          (tag) =>
              tag.category == TagCategory.artist && tag.name == 'ArtistName',
        ),
        isTrue,
      );
      expect(
        inferred.tags.where((tag) => tag.category == TagCategory.series),
        isEmpty,
      );
      expect(
        inferred.tags.any(
          (tag) =>
              tag.category == TagCategory.mediaType && tag.name == 'hitomi',
        ),
        isTrue,
      );
    });

    test('ignores bracketed numeric-only artist candidates', () {
      final tags = ImportTagRuleService.inferFromRelativePath(
        relativePathHint: 'kemono/[999]/sample.pdf',
      );

      expect(tags.where((tag) => tag.category == TagCategory.artist), isEmpty);
      expect(
        tags.any(
          (tag) =>
              tag.category == TagCategory.mediaType && tag.name == 'kemono',
        ),
        isTrue,
      );
    });

    test('uses all downloader metadata artists for hitomi artist and series', () {
      final inferred = ImportTagRuleService.inferForImportedItem(
        itemPath:
            r'C:\library\hitomi\[12345] ArtistName\[20241105] [3114110] Sample Title.pdf',
        rootFolderRaw: r'C:\library',
        displayName: '[20241105] [3114110] Sample Title.pdf',
        sourceUrls: const <String>['https://hitomi.la/reader/123456.html'],
        hitomiMetadata: const HitomiGalleryMetadata(
          artists: <String>['ArtistName', 'CoArtist'],
          series: <String>['Original Series'],
        ),
      );

      expect(
        inferred.tags
            .where((tag) => tag.category == TagCategory.artist)
            .map((tag) => tag.name)
            .toSet(),
        <String>{'ArtistName', 'CoArtist'},
      );
      expect(
        inferred.tags.any(
          (tag) =>
              tag.category == TagCategory.series &&
              tag.name == 'Original Series',
        ),
        isTrue,
      );
      expect(
        inferred.tags.any(
          (tag) =>
              tag.category == TagCategory.mediaType && tag.name == 'hitomi',
        ),
        isTrue,
      );
    });

    test('uses ddd-smart metadata for imported pdf auto tags', () {
      final inferred = ImportTagRuleService.inferForImportedItem(
        itemPath: r'C:\library\imports\sample.pdf',
        rootFolderRaw: r'C:\library',
        displayName: 'sample.pdf',
        sourceUrls: const <String>[
          'https://ddd-smart.net/doujinshi3/show-m.php?g=20260411&dir=0058&page=0',
        ],
        hitomiMetadata: const HitomiGalleryMetadata(
          artists: <String>['CircleName'],
          groups: <String>['CircleName'],
          series: <String>['Original Series'],
          characters: <String>['Heroine', 'Mage'],
          tags: <String>['TwinTail', 'BigBreasts'],
          mediaType: 'ddd-smart',
        ),
      );

      expect(
        inferred.tags
            .where((tag) => tag.category == TagCategory.artist)
            .map((tag) => tag.name)
            .toSet(),
        <String>{'CircleName'},
      );
      expect(
        inferred.tags.any(
          (tag) =>
              tag.category == TagCategory.series &&
              tag.name == 'Original Series',
        ),
        isTrue,
      );
      expect(
        inferred.tags
            .where((tag) => tag.category == TagCategory.character)
            .map((tag) => tag.name)
            .toSet(),
        <String>{'Heroine', 'Mage'},
      );
      expect(
        inferred.tags
            .where((tag) => tag.category == TagCategory.free)
            .map((tag) => tag.name)
            .toSet(),
        <String>{'TwinTail', 'BigBreasts'},
      );
      expect(
        inferred.tags.any(
          (tag) =>
              tag.category == TagCategory.mediaType &&
              tag.name == 'ddd-smart',
        ),
        isTrue,
      );
    });
  });
}
