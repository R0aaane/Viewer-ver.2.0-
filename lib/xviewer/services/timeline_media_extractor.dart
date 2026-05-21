import '../domain/models/media_post.dart';

class TimelineMediaExtractor {
  List<MediaPost> onlyImagePosts(List<MediaPost> posts) {
    return posts.where((post) => post.hasImages).toList(growable: false);
  }
}
