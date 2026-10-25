import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/models/tag.dart';
import 'package:pdf_viewer/widgets/gallery_tag_picker.dart';

void main() {
  const artist = Tag(name: 'Artist One', category: TagCategory.artist);
  const series = Tag(name: '作品シリーズ', category: TagCategory.series);

  test('counts PDFs once per category and handles spaces and category AND', () {
    final candidates = galleryTagCandidates([
      [artist, artist, series],
      [artist],
    ]);
    expect(candidates.first.count, 2);
    expect(candidates.last.count, 1);
    expect(matchesGalleryTags([artist, series], [artist, series]), isTrue);
    expect(matchesGalleryTags([artist], [artist, series]), isFalse);
    expect(
      matchesGalleryTags([const Tag(name: 'Artist One')], [artist]),
      isFalse,
    );
    expect(
      matchesGalleryTags(
        [const Tag(name: 'Artist One Extra', category: TagCategory.artist)],
        [artist],
      ),
      isFalse,
    );
  });

  testWidgets('browse without typing, switch category, filter and select', (
    tester,
  ) async {
    Tag? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showDialog<Tag>(
                  context: context,
                  builder: (_) => GalleryTagPicker(
                    candidates: galleryTagCandidates([
                      [artist, series],
                      [artist],
                    ]),
                    selected: const {},
                  ),
                );
              },
              child: const Text('開く'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('開く'));
    await tester.pumpAndSettle();
    expect(find.text('Artist One'), findsOneWidget);
    expect(find.text('2件'), findsOneWidget);
    await tester.tap(find.text('シリーズ'));
    await tester.pumpAndSettle();
    expect(find.text('作品シリーズ'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '該当なし');
    await tester.pump();
    expect(find.text('0候補'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '作品');
    await tester.pump();
    await tester.tap(find.text('作品シリーズ'));
    await tester.pumpAndSettle();
    expect(result?.name, series.name);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fits a narrow screen and closes without selection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: GalleryTagPicker(
          candidates: galleryTagCandidates([
            [artist],
          ]),
          selected: const {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Artist One'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
