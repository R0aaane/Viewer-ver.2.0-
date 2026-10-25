import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/web/web_top_entries.dart';

void main() {
  test('shelf selection matches full sort without modifying the library', () {
    final values = List.generate(5000, (index) => index)..shuffle(Random(42));
    final original = List.of(values);
    for (final limit in [0, 1, 10, 12, 6000]) {
      final expected = List.of(values)..sort((a, b) => b.compareTo(a));
      expect(
        webTopEntries(values, limit, (a, b) => b.compareTo(a)),
        expected.take(limit),
      );
    }
    expect(values, original);
  });

  test('ties retain input order and an empty library remains empty', () {
    final values = [(1, 'a'), (1, 'b'), (0, 'c'), (1, 'd')];
    expect(webTopEntries(values, 3, (a, b) => a.$1.compareTo(b.$1)), [
      (0, 'c'),
      (1, 'a'),
      (1, 'b'),
    ]);
    expect(webTopEntries<int>([], 12, (a, b) => a.compareTo(b)), isEmpty);
  });

  test(
    'large library uses a bounded number of comparisons for twelve entries',
    () {
      var comparisons = 0;
      final result = webTopEntries(List.generate(50000, (i) => 50000 - i), 12, (
        a,
        b,
      ) {
        comparisons++;
        return a.compareTo(b);
      });
      expect(result, List.generate(12, (i) => i + 1));
      expect(comparisons, lessThan(50000 * 6));
    },
  );
}
