import 'package:flutter/material.dart';

import '../models/metadata_settings.dart';
import '../services/app_settings_service.dart';
import '../web/web_remote_viewer_page.dart';
import 'app_bootstrap_shared.dart';
import 'app_theme.dart';

Future<void> bootstrapApp() async {
  WidgetsFlutterBinding.ensureInitialized();
  configureGlobalErrorHandling();

  final settingsService = AppSettingsService();
  final settings = await settingsService.loadMetadataSettings();

  runApp(
    WebViewerApp(
      initialSettings: settings,
      settingsService: settingsService,
    ),
  );
}

class WebViewerApp extends StatelessWidget {
  final MetadataSettings initialSettings;
  final AppSettingsService settingsService;

  const WebViewerApp({
    super.key,
    required this.initialSettings,
    required this.settingsService,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'メディアビューア Web',
      theme: buildAppTheme(),
      debugShowCheckedModeBanner: false,
      home: WebRemoteViewerPage(
        initialSettings: initialSettings,
        settingsService: settingsService,
      ),
    );
  }
}
