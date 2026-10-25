import 'dart:async';

/// Run optional work only after visible resources have loaded and UI has idled.
class WebDeferredPrefetch {
  final Duration delay;
  Timer? _timer;
  int _generation = 0;

  WebDeferredPrefetch({this.delay = const Duration(milliseconds: 300)});

  void cancel() {
    _generation++;
    _timer?.cancel();
    _timer = null;
  }

  void schedule(Iterable<Future<Object?>> visible, void Function() operation) {
    cancel();
    final generation = _generation;
    unawaited(
      Future.wait(visible).then<void>(
        (_) {
          if (generation != _generation) return;
          _timer = Timer(delay, () {
            if (generation == _generation) operation();
          });
        },
        onError: (Object _, StackTrace __) {
          // A failed visible request must not trigger more background requests.
        },
      ),
    );
  }
}
