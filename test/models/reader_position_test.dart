import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/models/reader_position.dart';
import 'package:pdf_viewer/models/reading_progress.dart';

ReadingProgressEntry _progress(int page, int? total) => ReadingProgressEntry(
  mediaId: 'test',
  title: 'test',
  folderRaw: '',
  currentPage: page,
  totalPages: total,
  progress: 0,
  lastReadAt: DateTime(2026),
  updatedAt: DateTime(2026),
  thumbnailUrl: null,
);

void main() {
  test('fresh document count wins over delayed stale history', () {
    final result = resolveReaderPosition(
      currentPage: 1,
      currentTotalPages: 6,
      documentTotalPages: 6,
      progress: _progress(20, 60),
      preserveInitialPage: false,
      hasMovedPage: false,
    );
    expect(result, (page: 6, totalPages: 6));
  });

  test('history supplies provisional count until document resolves', () {
    final result = resolveReaderPosition(
      currentPage: 1,
      currentTotalPages: 1,
      progress: _progress(20, 60),
      preserveInitialPage: false,
      hasMovedPage: false,
    );
    expect(result, (page: 20, totalPages: 60));
  });

  test('manual navigation is not replaced by delayed history', () {
    final result = resolveReaderPosition(
      currentPage: 3,
      currentTotalPages: 6,
      documentTotalPages: 6,
      progress: _progress(5, 60),
      preserveInitialPage: false,
      hasMovedPage: true,
    );
    expect(result, (page: 3, totalPages: 6));
  });

  test(
    'explicit initial page is preserved until a reliable count is known',
    () {
      final unresolved = resolveReaderPosition(
        currentPage: 8,
        currentTotalPages: 1,
        preserveInitialPage: true,
        hasMovedPage: false,
      );
      expect(unresolved, (page: 8, totalPages: 1));
      final resolved = resolveReaderPosition(
        currentPage: 8,
        currentTotalPages: 6,
        documentTotalPages: 6,
        preserveInitialPage: true,
        hasMovedPage: false,
      );
      expect(resolved, (page: 6, totalPages: 6));
    },
  );

  test('completed history still resumes at the first page', () {
    final result = resolveReaderPosition(
      currentPage: 3,
      currentTotalPages: 6,
      documentTotalPages: 6,
      progress: _progress(6, 6),
      preserveInitialPage: false,
      hasMovedPage: false,
    );
    expect(result, (page: 1, totalPages: 6));
  });
}
