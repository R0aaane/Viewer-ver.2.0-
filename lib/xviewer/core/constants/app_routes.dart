abstract final class AppRoutes {
  static const login = '/';
  static const timeline = '/timeline';
  static const saved = '/saved';
  static const savedAuthor = '/saved/author/:authorUsername';
  static const savedDetail = '/saved/:recordId';

  static String savedAuthorPath(String authorUsername) {
    return '/saved/author/${Uri.encodeComponent(authorUsername)}';
  }

  static String savedDetailPath(String recordId) {
    return '/saved/${Uri.encodeComponent(recordId)}';
  }
}
