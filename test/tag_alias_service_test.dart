import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/models/tag.dart';
import 'package:pdf_viewer/services/tag_alias_service.dart';

void main() {
  group('TagAliasService', () {
    final service = TagAliasService.fromJsonString('''
      {
        "series": {
          "東方Project": ["Touhou Project", "Touhou", "東方"]
        },
        "character": {
          "博麗霊夢": ["Hakurei Reimu", "Reimu Hakurei", "霊夢"]
        }
      }
    ''');

    test('canonicalizes configured alias to Japanese canonical name', () {
      final tag = service.canonicalizeTag(
        const Tag(name: 'Touhou Project', category: TagCategory.series),
      );
      expect(tag.name, '東方Project');
      expect(tag.category, TagCategory.series);
    });

    test('expands partial alias query to canonical and related names', () {
      expect(
        service.equivalentNames(
          TagCategory.character,
          'Reimu',
          partial: true,
        ),
        containsAll(<String>['博麗霊夢', 'Hakurei Reimu', 'Reimu Hakurei', 'Reimu']),
      );
    });

    test('matches canonical tag when searching by alias', () {
      expect(
        service.matchesTagName(
          TagCategory.series,
          '東方Project',
          'Touhou',
          partial: true,
        ),
        isTrue,
      );
    });
  });
}
