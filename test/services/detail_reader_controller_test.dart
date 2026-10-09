import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/models/mediaItem.dart';
import 'package:pdf_viewer/repository/mediaRepository.dart';
import 'package:pdf_viewer/scene/detailImage.dart';

class _Repository extends Fake implements MediaRepository {
  int calls = 0;
  int renders = 0;
  @override
  Future<Uint8List> renderPageBytes(
    MediaItem item,
    int page, {
    int maxWidth = 1600,
  }) async {
    renders++;
    return Uint8List.fromList([page]);
  }

  @override
  Future<int> getPageCount(MediaItem item) async {
    calls++;
    return 4;
  }
}

void main() {
  for (final dispose in [false, true]) {
    testWidgets(
      '${dispose ? "dispose" : "cache invalidation"} cancels queued and pre-frame renders',
      (tester) async {
        final repo = _Repository();
        const item = MediaItem(
          id: 'a',
          displayName: 'a.pdf',
          kind: MediaKind.pdf,
          folderRaw: '',
        );
        final controller = DetailReaderController(repo: repo, initialIndex: 0);
        final cancelled = [
          for (var page = 1; page <= 3; page++)
            expectLater(
              controller.loadReaderBytes(item, page, useStaticFrame: false),
              throwsA(isA<Exception>()),
            ),
        ];
        if (dispose) {
          controller.dispose();
        } else {
          controller.clearCaches();
        }
        await tester.pump();
        await Future.wait(cancelled);
        expect(repo.renders, 0);
        if (dispose) {
          expect(
            () => controller.loadReaderBytes(item, 1, useStaticFrame: false),
            throwsStateError,
          );
        } else {
          final fresh = controller.loadReaderBytes(
            item,
            1,
            useStaticFrame: false,
          );
          await tester.pump();
          expect(await fresh, [1]);
          expect(repo.renders, 1);
          controller.dispose();
        }
      },
    );
  }

  test(
    'page count preload is consumed once, including after a page edit',
    () async {
      final repo = _Repository();
      const item = MediaItem(
        id: 'a',
        displayName: 'a.pdf',
        kind: MediaKind.pdf,
        folderRaw: '',
      );
      final controller = DetailReaderController(
        repo: repo,
        initialIndex: 0,
        initialPreloadItemId: item.id,
        initialPageCountFuture: Future.value(5),
      );
      expect(await controller.getPageCountForCurrent(item, 0), 5);
      controller.clearCaches();
      expect(await controller.getPageCountForCurrent(item, 0), 4);
      expect(repo.calls, 1);
    },
  );

  test('a failed preload permits a fresh page count request', () async {
    final repo = _Repository();
    const item = MediaItem(
      id: 'a',
      displayName: 'a.pdf',
      kind: MediaKind.pdf,
      folderRaw: '',
    );
    final controller = DetailReaderController(
      repo: repo,
      initialIndex: 0,
      initialPreloadItemId: item.id,
      initialPageCountFuture: Future.error(StateError('open failed')),
    );
    await expectLater(
      controller.getPageCountForCurrent(item, 0),
      throwsStateError,
    );
    expect(await controller.getPageCountForCurrent(item, 0), 4);
  });
}
