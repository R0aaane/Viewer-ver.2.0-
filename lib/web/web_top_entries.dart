/// Select a small shelf without allocating or sorting the entire library.
List<T> webTopEntries<T>(
  Iterable<T> entries,
  int limit,
  Comparator<T> compare,
) {
  if (limit <= 0) return <T>[];
  final top = <T>[];
  for (final entry in entries) {
    if (top.length == limit && compare(entry, top.last) >= 0) continue;
    var low = 0;
    var high = top.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (compare(entry, top[mid]) < 0) {
        high = mid;
      } else {
        low = mid + 1;
      }
    }
    top.insert(low, entry);
    if (top.length > limit) top.removeLast();
  }
  return top;
}
