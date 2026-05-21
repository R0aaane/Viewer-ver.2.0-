import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../xviewer/app/app.dart';
import '../xviewer/core/bootstrap.dart';

class XViewerPage extends StatefulWidget {
  const XViewerPage({super.key});

  @override
  State<XViewerPage> createState() => _XViewerPageState();
}

class _XViewerPageState extends State<XViewerPage> {
  late final Future<void> _bootstrapFuture = bootstrap();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _bootstrapFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            appBar: AppBar(title: const Text('XViewer')),
            body: Center(
              child: Text('XViewer initialization failed: ${snapshot.error}'),
            ),
          );
        }

        if (snapshot.connectionState != ConnectionState.done) {
          return Scaffold(
            appBar: AppBar(title: const Text('XViewer')),
            body: const Center(child: CircularProgressIndicator()),
          );
        }

        return ProviderScope(
          child: XViewerApp(onClose: () => Navigator.of(context).pop()),
        );
      },
    );
  }
}
