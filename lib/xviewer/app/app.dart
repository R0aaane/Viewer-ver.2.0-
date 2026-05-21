import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/settings/presentation/providers/app_preferences_controller.dart';
import 'router.dart';
import 'theme.dart';
import 'xviewer_shell_controller.dart';

class XViewerApp extends ConsumerWidget {
  const XViewerApp({super.key, this.onClose});

  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    final preferences = ref.watch(appPreferencesProvider);

    return ProviderScope(
      overrides: [xViewerCloseHandlerProvider.overrideWithValue(onClose)],
      child: MaterialApp.router(
        title: 'Xviewer',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(
          useBlackBackground: preferences.useBlackBackground,
        ),
        routerConfig: router,
      ),
    );
  }
}
