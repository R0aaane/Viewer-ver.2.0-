import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/web/web_deferred_prefetch.dart';

void main() {
  testWidgets('prefetch waits for both visible pages and the idle delay', (
    tester,
  ) async {
    final scheduler = WebDeferredPrefetch();
    addTearDown(scheduler.cancel);
    final left = Completer<Object?>();
    final right = Completer<Object?>();
    var calls = 0;
    scheduler.schedule([left.future, right.future], () => calls++);
    left.complete();
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 0);
    right.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 299));
    expect(calls, 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(calls, 1);
  });

  testWidgets('page changes and closing cancel pending prefetch', (
    tester,
  ) async {
    final scheduler = WebDeferredPrefetch();
    final old = Completer<Object?>();
    var stale = 0;
    var latest = 0;
    scheduler.schedule([old.future], () => stale++);
    scheduler.schedule([], () => latest++);
    old.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(stale, 0);
    expect(latest, 1);
    scheduler.schedule([], () => latest++);
    await tester.pump();
    scheduler.cancel();
    await tester.pump(const Duration(seconds: 1));
    expect(latest, 1);
  });

  testWidgets('a failed visible page does not start background work', (
    tester,
  ) async {
    final scheduler = WebDeferredPrefetch();
    addTearDown(scheduler.cancel);
    final visible = Completer<Object?>();
    var calls = 0;
    scheduler.schedule([visible.future], () => calls++);
    visible.completeError(StateError('network error'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 0);
    expect(tester.takeException(), isNull);
  });
}
