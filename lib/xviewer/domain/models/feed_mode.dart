enum FeedMode {
  reposted,
  timeline,
  liked,
}

extension FeedModeX on FeedMode {
  String get label {
    switch (this) {
      case FeedMode.reposted:
        return 'Reposted Images';
      case FeedMode.timeline:
        return 'Timeline Images';
      case FeedMode.liked:
        return 'Liked Images';
    }
  }

  String get shortLabel {
    switch (this) {
      case FeedMode.reposted:
        return 'Reposts';
      case FeedMode.timeline:
        return 'Timeline';
      case FeedMode.liked:
        return 'Likes';
    }
  }
}
