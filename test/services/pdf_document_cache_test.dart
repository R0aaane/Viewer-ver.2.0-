import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/services/pdf_document_cache.dart';

import '../support/fake_pdf.dart';

void main() {
  test(
    'queued readers share one open and never use an evicted document',
    () async {
      final cache = PdfDocumentCache(maxEntries: 1);
      final first = FakePdfDocument();
      final second = FakePdfDocument();
      final opened = Completer<void>();
      final release = Completer<void>();
      var openCount = 0;
      final reading = cache.use(
        'a',
        () async {
          openCount++;
          return first;
        },
        (doc) async {
          opened.complete();
          await release.future;
          expect(first.closed, isFalse);
        },
      );
      await opened.future;
      final queued = cache.use('a', () async {
        openCount++;
        return first;
      }, (doc) async => expect(first.closed, isFalse));
      await cache.use('b', () async => second, (_) async {});
      expect(first.closed, isFalse);
      expect(second.closed, isTrue);
      release.complete();
      await Future.wait([reading, queued]);
      expect(openCount, 1);
      await cache.dispose();
      expect(first.closeCount, 1);
    },
  );

  test('dispose drains accepted operations and rejects new readers', () async {
    final cache = PdfDocumentCache();
    final doc = FakePdfDocument();
    final opening = Completer<FakePdfDocument>();
    final reading = cache.use('a', () => opening.future, (_) async => 7);
    final disposal = cache.dispose();
    await expectLater(cache.run('b', () async {}), throwsStateError);
    opening.complete(doc);
    expect(await reading, 7);
    await disposal;
    await cache.dispose();
    expect(doc.closeCount, 1);
    expect(cache.pinnedPaths, isEmpty);
  });

  test('open/render errors do not poison the queue', () async {
    final cache = PdfDocumentCache();
    final doc = FakePdfDocument();
    await expectLater(
      cache.use('a', () async => throw StateError('open'), (_) async {}),
      throwsStateError,
    );
    await expectLater(
      cache.use('a', () async => doc, (_) async => throw StateError('render')),
      throwsStateError,
    );
    expect(await cache.use('a', () async => doc, (_) async => 3), 3);
    await cache.dispose();
    expect(doc.closeCount, 1);
  });

  test('invalidation waits for an active document before closing it', () async {
    final cache = PdfDocumentCache();
    final doc = FakePdfDocument();
    final release = Completer<void>();
    final reading = cache.use('a', () async => doc, (_) => release.future);
    final eviction = cache.evictWhere((key) => key == 'a');
    await Future<void>.delayed(Duration.zero);
    expect(doc.closed, isFalse);
    release.complete();
    await Future.wait([reading, eviction]);
    expect(doc.closeCount, 1);
    await cache.dispose();
  });
}
