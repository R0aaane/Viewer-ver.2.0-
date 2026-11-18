@TestOn('browser')
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/app/app_theme.dart';
import 'package:pdf_viewer/web/web_remote_api_client.dart';
import 'package:pdf_viewer/web/web_remote_viewer_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final width in [320.0, 1280.0]) {
    testWidgets('reader focus mode at ${width.toInt()}px', (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: WebPdfViewerPage(
            client: WebRemoteApiClient(baseUrl: 'http://localhost'),
            entry: const WebRemoteEntry(
              entryId: 'fixture',
              displayName: 'Fixture.pdf',
              folderRaw: 'fixture',
              kind: 'pdf',
              mediaId: null,
              fullPath: null,
              sizeBytes: null,
              modifiedAt: null,
              stats: null,
            ),
            onOpenDetail: () async {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      Future<void> enterFocusMode() async {
        if (width < 400) {
          await tester.tap(find.byTooltip('表示オプション'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('集中表示'));
        } else {
          await tester.tap(find.byTooltip('集中表示'));
        }
        await tester.pumpAndSettle();
        expect(find.byTooltip('前のページ'), findsNothing);
        expect(find.byTooltip('集中表示を解除'), findsOneWidget);
      }

      await enterFocusMode();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byTooltip('前のページ'), findsOneWidget);
      await enterFocusMode();
      await tester.tap(find.byTooltip('集中表示を解除'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('前のページ'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
