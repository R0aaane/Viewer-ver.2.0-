import 'dart:async';

/// Only poll at input frequency while a controller is connected and visible.
class WebGamepadPoller {
  final bool Function() poll;
  final bool Function() isActive;
  Timer? _timer;
  bool _disposed = false;

  WebGamepadPoller({required this.poll, required this.isActive}) {
    _schedule(const Duration(milliseconds: 500));
  }

  void _schedule(Duration delay) {
    _timer = Timer(delay, () {
      if (_disposed) return;
      final connected = isActive() && poll();
      if (!_disposed) {
        _schedule(Duration(milliseconds: connected ? 80 : 500));
      }
    });
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }
}
