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

  test(
    'mutation drains readers and prevents reopening until the change finishes',
    () async {
      final cache = PdfDocumentCache();
      final old = FakePdfDocument();
      final replacement = FakePdfDocument();
      final readingStarted = Completer<void>();
      final releaseReader = Completer<void>();
      final mutationStarted = Completer<void>();
      final releaseMutation = Completer<void>();
      var opens = 0;
      final reading = cache.use('a', () async => old, (_) async {
        readingStarted.complete();
        await releaseReader.future;
        expect(old.closed, isFalse);
      });
      await readingStarted.future;
      final changing = cache.mutateWhere((key) => key == 'a', () async {
        expect(old.closed, isTrue);
        mutationStarted.complete();
        await releaseMutation.future;
      });
      final reopened = cache.use('a', () async {
        opens++;
        return replacement;
      }, (doc) async => doc);
      await Future<void>.delayed(Duration.zero);
      expect(mutationStarted.isCompleted, isFalse);
      releaseReader.complete();
      await mutationStarted.future;
      expect(opens, 0);
      releaseMutation.complete();
      await Future.wait([reading, changing]);
      expect(await reopened, same(replacement));
      expect(old.closeCount, 1);
      await cache.dispose();
      expect(replacement.closeCount, 1);
    },
  );

  test('overlapping mutations preserve accepted operation order', () async {
    final cache = PdfDocumentCache();
    final events = <String>[];
    final first = cache.mutateWhere(
      (_) => true,
      () async => events.add('first'),
    );
    final between = cache.run('a', () async => events.add('between'));
    final second = cache.mutateWhere(
      (_) => true,
      () async => events.add('second'),
    );
    final after = cache.run('b', () async => events.add('after'));
    await Future.wait([first, between, second, after]);
    expect(events, ['first', 'between', 'second', 'after']);
    await cache.dispose();
  });

  test(
    'failed mutation releases the barrier and disposal drains accepted work',
    () async {
      final cache = PdfDocumentCache();
      final release = Completer<void>();
      final changing = cache.mutateWhere((_) => true, () async {
        await release.future;
        throw StateError('mutation failed');
      });
      final failure = expectLater(changing, throwsStateError);
      final doc = FakePdfDocument();
      final reading = cache.use('a', () async => doc, (_) async => 42);
      final disposal = cache.dispose();
      await expectLater(
        cache.mutateWhere((_) => true, () async {}),
        throwsStateError,
      );
      release.complete();
      await failure;
      expect(await reading, 42);
      await disposal;
      expect(doc.closeCount, 1);
    },
  );
}
