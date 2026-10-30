import 'dart:js_interop';

import 'package:flutter/material.dart';

import '../models/metadata_settings.dart';
import '../services/app_settings_service.dart';
import '../services/controller_navigation_service.dart';
import '../web/web_remote_viewer_page.dart';
import '../web/web_diagnostic_binding.dart';
import '../web/web_japanese_fonts.dart';
import 'app_bootstrap_shared.dart';
import 'app_content_mode.dart';
import 'app_theme.dart';

@JS('pdfViewerRecordRenderPhase')
external JSFunction? get _phaseReporter;

@JS('__pdfViewerFontsReady')
external set _fontReady(JSBoolean value);

Future<void> bootstrapApp() async {
  if (Uri.base.queryParameters['perf'] == '1') {
    WebDiagnosticBinding(report: (phase, milliseconds) {
      _phaseReporter?.callAsFunction(null, phase.toJS, milliseconds.toJS);
    });
  } else {
    WidgetsFlutterBinding.ensureInitialized();
  }
  configureGlobalErrorHandling();

  // Fetch/register fonts alongside preferences, before the first app frame.
  final fontsReady = loadWebJapaneseFonts().then(
    (_) => true,
    onError: (Object error, StackTrace stack) {
      debugPrint('[WebBootstrap] Bundled font unavailable; using fallback: $error');
      return false;
    },
  );

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

  final hasJapaneseFonts = await fontsReady;
  _fontReady = true.toJS;
  runApp(WebViewerApp(
    initialSettings: settings,
    settingsService: settingsService,
    fontFamily: hasJapaneseFonts ? webJapaneseFontFamily : null,
  ));
}

class WebViewerApp extends StatelessWidget {
  final MetadataSettings initialSettings;
  final AppSettingsService settingsService;
  final String? fontFamily;

  const WebViewerApp({
    super.key,
    required this.initialSettings,
    required this.settingsService,
    this.fontFamily,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppContentModeConfig.isReader
          ? '紙魚'
          : '紙魚 R18 Web',
      theme: buildAppTheme(fontFamily: fontFamily),
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
