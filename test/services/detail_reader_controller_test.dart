import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/models/mediaItem.dart';
import 'package:pdf_viewer/repository/mediaRepository.dart';
import 'package:pdf_viewer/scene/detailImage.dart';

class _Repository extends Fake implements MediaRepository {
  int calls = 0;
  @override
  Future<int> getPageCount(MediaItem item) async {
    calls++;
    return 4;
  }
}

void main() {
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
