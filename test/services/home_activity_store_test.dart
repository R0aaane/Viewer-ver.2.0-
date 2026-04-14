import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pdf_viewer/models/mediaItem.dart';
import 'package:pdf_viewer/services/home_activity_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test(
    'recordView keeps the latest entry first and deduplicates by item id',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final pdf = MediaItem(
        id: 'C:\\library\\sample.pdf',
        displayName: 'sample.pdf',
        kind: MediaKind.pdf,
        folderRaw: 'C:\\library',
      );

      await HomeActivityStore.recordView(
        prefs,
        item: pdf,
        lastPage: 3,
        viewedAt: DateTime.fromMillisecondsSinceEpoch(1000),
      );
      await HomeActivityStore.recordView(
        prefs,
        item: pdf,
        lastPage: 18,
        viewedAt: DateTime.fromMillisecondsSinceEpoch(2000),
      );

      final entries = HomeActivityStore.readRecentViews(prefs);
      expect(entries, hasLength(1));
      expect(entries.single.itemId, pdf.id);
      expect(entries.single.lastPage, 18);
      expect(
        entries.single.viewedAt,
        DateTime.fromMillisecondsSinceEpoch(2000),
      );
    },
  );

  test('recordView stores null page for images', () async {
    final prefs = await SharedPreferences.getInstance();
    final image = MediaItem(
      id: 'C:\\library\\cover.jpg',
      displayName: 'cover.jpg',
      kind: MediaKind.image,
      folderRaw: 'C:\\library',
    );

    await HomeActivityStore.recordView(
      prefs,
      item: image,
      lastPage: 7,
      viewedAt: DateTime.fromMillisecondsSinceEpoch(3000),
    );

    final entries = HomeActivityStore.readRecentViews(prefs);
    expect(entries, hasLength(1));
    expect(entries.single.itemId, image.id);
    expect(entries.single.lastPage, isNull);
  });

  test(
    'recordView removes pdf from recent views when reaching the last page',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final pdf = MediaItem(
        id: 'C:\\library\\sample.pdf',
        displayName: 'sample.pdf',
        kind: MediaKind.pdf,
        folderRaw: 'C:\\library',
      );
      final image = MediaItem(
        id: 'C:\\library\\cover.jpg',
        displayName: 'cover.jpg',
        kind: MediaKind.image,
        folderRaw: 'C:\\library',
      );

      await HomeActivityStore.recordView(
        prefs,
        item: image,
        viewedAt: DateTime.fromMillisecondsSinceEpoch(1000),
      );
      await HomeActivityStore.recordView(
        prefs,
        item: pdf,
        lastPage: 7,
        totalPages: 12,
        viewedAt: DateTime.fromMillisecondsSinceEpoch(2000),
      );
      await HomeActivityStore.recordView(
        prefs,
        item: pdf,
        lastPage: 12,
        totalPages: 12,
        viewedAt: DateTime.fromMillisecondsSinceEpoch(3000),
      );

      final entries = HomeActivityStore.readRecentViews(prefs);
      expect(entries, hasLength(1));
      expect(entries.single.itemId, image.id);
    },
  );
}
