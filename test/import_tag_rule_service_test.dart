import 'package:flutter_test/flutter_test.dart';

import 'package:pdf_viewer/models/tag.dart';
import 'package:pdf_viewer/services/import_tag_rule_service.dart';

void main() {
  group('ImportTagRuleService', () {
    test('infers hitomi and artist tags for generated pdf context', () {
      final inferred = ImportTagRuleService.inferForGeneratedPdf(
        sourceFolderRaw: r'C:\library\hitomi\[12345] ArtistName',
        sourceFolderLabel: '[12345] ArtistName',
        generatedFileName: 'sample.pdf',
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

      expect(
        tags.where((tag) => tag.category == TagCategory.artist),
        isEmpty,
      );
      expect(
        tags.any(
          (tag) =>
              tag.category == TagCategory.mediaType && tag.name == 'kemono',
        ),
        isTrue,
      );
    });

    test('infers artist and mediaType for imported pdf path', () {
      final inferred = ImportTagRuleService.inferForImportedItem(
        itemPath: r'C:\library\hitomi\[12345] ArtistName\sample.pdf',
        rootFolderRaw: r'C:\library',
        displayName: 'sample.pdf',
        sourceUrls: const <String>['https://hitomi.la/reader/123456.html'],
      );

      expect(
        inferred.tags.any(
          (tag) =>
              tag.category == TagCategory.artist && tag.name == 'ArtistName',
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
  });
}
