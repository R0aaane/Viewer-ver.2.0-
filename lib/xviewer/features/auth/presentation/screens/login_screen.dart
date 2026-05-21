import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/xviewer_shell_controller.dart';
import '../../../../core/constants/app_routes.dart';
import '../../../../widgets/async_value_view.dart';
import '../providers/auth_controller.dart';

class LoginScreen extends ConsumerWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authControllerProvider);
    final closeXViewer = ref.watch(xViewerCloseHandlerProvider);
    debugPrint(
      '[xviewer][flutter] LoginScreen build: authValueHasData=${authState.hasValue} currentIsLoggedIn=${authState.valueOrNull?.isAuthenticated == true}',
    );

    ref.listen(authControllerProvider, (previous, next) {
      next.whenData((auth) {
        debugPrint(
          '[xviewer][flutter] LoginScreen auth listener: currentIsLoggedIn=${auth.isAuthenticated}',
        );
        if (auth.isAuthenticated && context.mounted) {
          context.go(AppRoutes.timeline);
        }
      });
    });

    return Scaffold(
      appBar: closeXViewer == null
          ? null
          : AppBar(
              leading: IconButton(
                onPressed: closeXViewer,
                icon: const Icon(Icons.arrow_back_rounded),
                tooltip: 'Back to pdf_viewer',
              ),
              title: const Text('XViewer'),
            ),
      body: SafeArea(
        child: AsyncValueView(
          value: authState,
          loadingLabel: 'Checking login state...',
          onRetry: () => ref.invalidate(authControllerProvider),
          data: (auth) {
            final user = auth.user;
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Xviewer',
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'MVP for collecting image posts from your X timeline.',
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                      const SizedBox(height: 24),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                user == null
                                    ? 'Logged out'
                                    : 'Logged in: @${user.username}',
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Mode: ${auth.loginModeLabel}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              if (auth.session != null) ...[
                                const SizedBox(height: 4),
                                Text(
                                  'Session user: ${auth.session!.displayName}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: () async {
                          await ref
                              .read(authControllerProvider.notifier)
                              .signIn();
                        },
                        icon: const Icon(Icons.login_rounded),
                        label: const Text('Sign in with X'),
                      ),
                      if (user != null) ...[
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: () => context.go(AppRoutes.timeline),
                          child: const Text('Open timeline'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
