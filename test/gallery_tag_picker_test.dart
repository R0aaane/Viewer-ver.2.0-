import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/models/tag.dart';
import 'package:pdf_viewer/widgets/gallery_tag_picker.dart';

void main() {
  test('random previews only sample matching PDFs and preserve counts', () {
    const artist = Tag(name: 'Artist', category: TagCategory.artist);
    const character = Tag(name: 'Character', category: TagCategory.character);
    final samples = <int>{};
    for (var seed = 0; seed < 50; seed++) {
      final candidates = galleryTagCandidates([
        [artist, artist],
        [character],
        [artist],
      ], random: Random(seed));
      final a = candidates.first;
      expect(a.count, 2);
      expect([0, 2], contains(a.previewIndex));
      expect(candidates.last.previewIndex, 1);
      samples.add(a.previewIndex!);
    }
    expect(samples, {0, 2});
  });

  testWidgets('previews are lazy, bounded and stop when the picker closes', (
    tester,
  ) async {
    final requests = <int>[];
    final pending = <Completer<Uint8List>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: GalleryTagPicker(
          candidates: [
            for (var i = 0; i < 100; i++)
              GalleryTagCandidate(
                Tag(
                  name: 'Artist ${i.toString().padLeft(3, '0')}',
                  category: TagCategory.artist,
                ),
                1,
                previewIndex: i,
              ),
          ],
          selected: const {},
          loadThumbnail: (index) {
            requests.add(index);
            final completer = Completer<Uint8List>();
            pending.add(completer);
            return completer.future;
          },
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(requests.length, 2);
    expect(requests.every((index) => index < 10), isTrue);
    // Failed previews must not prevent selection or issue requests for all tags.
    pending[0].completeError(StateError('unavailable'));
    await tester.pump();
    expect(find.text('Artist 000'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    final before = requests.length;
    for (final completer in pending) {
      if (!completer.isCompleted) completer.completeError(StateError('closed'));
    }
    await tester.pump(const Duration(milliseconds: 200));
    expect(requests.length, before);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cached candidate order refreshes when tag data changes', (
    tester,
  ) async {
    Widget picker(List<GalleryTagCandidate> candidates) => MaterialApp(
      home: GalleryTagPicker(candidates: candidates, selected: const {}),
    );
    const alpha = Tag(name: 'Alpha', category: TagCategory.artist);
    const beta = Tag(name: 'Beta', category: TagCategory.artist);
    await tester.pumpWidget(
      picker(const [
        GalleryTagCandidate(alpha, 1),
        GalleryTagCandidate(beta, 3),
      ]),
    );
    expect(
      tester.getTopLeft(find.text('Beta')).dy,
      lessThan(tester.getTopLeft(find.text('Alpha')).dy),
    );
    await tester.pumpWidget(picker(const [GalleryTagCandidate(alpha, 5)]));
    expect(find.text('Beta'), findsNothing);
    expect(find.text('5件'), findsOneWidget);
  });

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
