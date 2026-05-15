import 'package:flutter/material.dart';

import '../models/metadata_settings.dart';
import '../services/app_settings_service.dart';
import '../services/controller_navigation_service.dart';
import '../web/web_remote_viewer_page.dart';
import 'app_bootstrap_shared.dart';
import 'app_content_mode.dart';
import 'app_theme.dart';

Future<void> bootstrapApp() async {
  WidgetsFlutterBinding.ensureInitialized();
  configureGlobalErrorHandling();

  final settingsService = AppSettingsService();
  MetadataSettings settings = const MetadataSettings();
  try {
    settings = await settingsService.loadMetadataSettings().timeout(
      const Duration(seconds: 4),
    );
  } catch (error, stackTrace) {
    debugPrint('[WebBootstrap] Failed to load settings: $error');
    debugPrintStack(label: '[WebBootstrap]', stackTrace: stackTrace);
  }

  runApp(
    WebViewerApp(initialSettings: settings, settingsService: settingsService),
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
      title: AppContentModeConfig.isReader
          ? 'Book Reader Web'
          : 'pdf_viewer R18 Web',
      theme: buildAppTheme(),
      debugShowCheckedModeBanner: false,
      builder: (context, child) =>
          ControllerNavigationShell(child: child ?? const SizedBox.shrink()),
      home: WebRemoteViewerPage(
        initialSettings: initialSettings,
        settingsService: settingsService,
      ),
    );
  }
}
