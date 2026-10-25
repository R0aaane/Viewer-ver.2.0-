class WebPerformancePolicy {
  final bool reduceEffects;

  const WebPerformancePolicy({required this.reduceEffects});

  factory WebPerformancePolicy.fromUserAgent(String userAgent) {
    // Include WebKit iOS browsers and iPadOS desktop user agents.
    final webKit = userAgent.contains('AppleWebKit');
    final chromium = RegExp(
      r'Chrome/|Chromium/|Edg/|OPR/|Android',
    ).hasMatch(userAgent);
    return WebPerformancePolicy(reduceEffects: webKit && !chromium);
  }

  int thumbnailDimension(double logicalSize) {
    final pixels = (logicalSize * 1.8).round();
    return reduceEffects ? pixels.clamp(1, 1024) : pixels;
  }
}
