import 'package:flutter/material.dart';

import '../database/app_db.dart';
import '../database/tag_service.dart';
import '../repository/mediaRepository.dart';
import '../repository/repositoryFactory.dart';
import '../scene/gridGallery.dart';
import '../services/app_version_service.dart';
import '../services/controller_navigation_service.dart';
import '../services/host_api_server_service.dart';
import 'app_bootstrap_shared.dart';
import 'app_theme.dart';

Future<void> bootstrapApp() async {
  WidgetsFlutterBinding.ensureInitialized();
  configureGlobalErrorHandling();

  final appDb = AppDb();
  final tagService = TagService(appDb);
  await AppVersionService().recordCurrentVersion();
  await tagService.initialize();
  final hostServerService = HostApiServerService();
  await hostServerService.refresh();

  final repo = createRepository(
    appDb,
    initialSettings: tagService.settings,
    localUploadTagsProvider: tagService.listLocallyStoredTagsForItems,
  );

  runApp(
    MyApp(
      appDb: appDb,
      tagService: tagService,
      repo: repo,
      hostServerService: hostServerService,
    ),
  );
}

class MyApp extends StatelessWidget {
  final AppDb appDb;
  final TagService tagService;
  final MediaRepository repo;
  final HostApiServerService hostServerService;

  const MyApp({
    super.key,
    required this.appDb,
    required this.tagService,
    required this.repo,
    required this.hostServerService,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'メディアビューア',
      theme: buildAppTheme(),
      builder: (context, child) =>
          ControllerNavigationShell(child: child ?? const SizedBox.shrink()),
      home: GalleryGridPage(
        repo: repo,
        tagService: tagService,
        hostServerService: hostServerService,
      ),
    );
  }
}
