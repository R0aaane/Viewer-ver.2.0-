import 'reading_progress.dart';

/// Resolves asynchronous history against the current document, without allowing
/// stale saved page counts to overwrite a freshly opened/edited PDF's count.
({int page, int totalPages}) resolveReaderPosition({
  required int currentPage,
  required int currentTotalPages,
  int? documentTotalPages,
  ReadingProgressEntry? progress,
  required bool preserveInitialPage,
  required bool hasMovedPage,
}) {
  final savedTotal = progress?.totalPages;
  final total =
      documentTotalPages ??
      (savedTotal != null && savedTotal > 0 ? savedTotal : currentTotalPages);
  final next = progress != null && !preserveInitialPage && !hasMovedPage
      ? (progress.isCompleted ? 1 : progress.currentPage)
      : currentPage;
  final keepUnresolvedInitial =
      preserveInitialPage && savedTotal == null && documentTotalPages == null;
  return (
    page: total > 0 && !keepUnresolvedInitial
        ? next.clamp(1, total)
        : (next < 1 ? 1 : next),
    totalPages: total,
  );
}
