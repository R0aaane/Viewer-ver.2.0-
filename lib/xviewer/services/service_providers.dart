import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'creator_display_name_service.dart';
import 'creator_site_resolver_service.dart';
import 'link_launcher_service.dart';

final linkLauncherServiceProvider = Provider<LinkLauncherService>(
  (ref) => LinkLauncherService(),
);

final creatorSiteResolverServiceProvider = Provider<CreatorSiteResolverService>(
  (ref) => CreatorSiteResolverService(Dio()),
);

final creatorDisplayNameServiceProvider = Provider<CreatorDisplayNameService>(
  (ref) => CreatorDisplayNameService(Dio()),
);
