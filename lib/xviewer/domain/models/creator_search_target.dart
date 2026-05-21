import 'package:flutter/material.dart';

enum CreatorSearchTarget {
  hitomi,
  kemono,
  dddSmart,
  crossSiteSearch,
}

class CreatorSearchMatch {
  const CreatorSearchMatch({
    required this.target,
    required this.title,
    required this.url,
  });

  final CreatorSearchTarget target;
  final String title;
  final String url;
}

extension CreatorSearchTargetDetails on CreatorSearchTarget {
  String get label {
    return switch (this) {
      CreatorSearchTarget.hitomi => 'hitomi',
      CreatorSearchTarget.kemono => 'kemono',
      CreatorSearchTarget.dddSmart => 'ddd-smart',
      CreatorSearchTarget.crossSiteSearch => 'Google',
    };
  }

  String get description {
    return switch (this) {
      CreatorSearchTarget.hitomi => 'Search hitomi by creator name',
      CreatorSearchTarget.kemono => 'Search kemono creators',
      CreatorSearchTarget.dddSmart => 'Search ddd-smart circles',
      CreatorSearchTarget.crossSiteSearch => 'Search all configured sites',
    };
  }

  String get mark {
    return switch (this) {
      CreatorSearchTarget.hitomi => 'H',
      CreatorSearchTarget.kemono => 'K',
      CreatorSearchTarget.dddSmart => 'D',
      CreatorSearchTarget.crossSiteSearch => 'G',
    };
  }

  String get faviconUrl {
    return switch (this) {
      CreatorSearchTarget.hitomi => 'https://hitomi.la/favicon.ico',
      CreatorSearchTarget.kemono => 'https://kemono.cr/favicon.ico',
      CreatorSearchTarget.dddSmart => 'https://ddd-smart.net/favicon.ico',
      CreatorSearchTarget.crossSiteSearch =>
        'https://www.google.com/favicon.ico',
    };
  }

  String? get faviconAssetPath {
    return switch (this) {
      CreatorSearchTarget.hitomi => 'assets/favicons/hitomi.png',
      CreatorSearchTarget.kemono => 'assets/favicons/kemono.png',
      CreatorSearchTarget.dddSmart => null,
      CreatorSearchTarget.crossSiteSearch => null,
    };
  }

  IconData get icon {
    return switch (this) {
      CreatorSearchTarget.hitomi => Icons.image_search_rounded,
      CreatorSearchTarget.kemono => Icons.person_search_rounded,
      CreatorSearchTarget.dddSmart => Icons.menu_book_rounded,
      CreatorSearchTarget.crossSiteSearch => Icons.travel_explore_rounded,
    };
  }

  Uri buildUri(String creatorName) {
    final query = creatorName.trim();
    return switch (this) {
      CreatorSearchTarget.hitomi => Uri.parse(
        'https://hitomi.la/search.html?'
        '${Uri.encodeComponent('artist:${_hitomiArtistTag(query)} language:japanese')}',
      ),
      CreatorSearchTarget.kemono => Uri.https(
        'kemono.cr',
        '/artists',
        {'q': query},
      ),
      CreatorSearchTarget.dddSmart => Uri.parse(
        'https://ddd-smart.net/list2.php?'
        'keyword=${Uri.encodeQueryComponent(query)}'
        '&s=%E6%A4%9C%E7%B4%A2&type=3',
      ),
      CreatorSearchTarget.crossSiteSearch => Uri.https(
        'www.google.com',
        '/search',
        {
          'q': '$query (site:hitomi.la OR site:kemono.cr OR '
              'site:ddd-smart.net)',
        },
      ),
    };
  }

  String _hitomiArtistTag(String value) {
    return value.trim().replaceAll(RegExp(r'\s+'), '_');
  }
}
