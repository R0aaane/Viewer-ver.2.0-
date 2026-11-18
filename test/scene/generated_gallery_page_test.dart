import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/scene/generated_gallery_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('shows ComfyUI availability and keeps startup errors visible', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final firstCheck = Completer<bool>();
    final startup = Completer<void>();
    var checkCount = 0;
    var available = false;
    await tester.pumpWidget(
      MaterialApp(
        home: GeneratedGalleryPage(
          baseUrl: 'http://fixture.invalid',
          checkComfy: () async {
            if (checkCount++ == 0) return firstCheck.future;
            return available;
          },
          reconnect: () => startup.future,
        ),
      ),
    );

    expect(find.text('ComfyUIの接続を確認中…'), findsOneWidget);
    firstCheck.complete(false);
    await tester.pumpAndSettle();
    expect(find.text('ComfyUI 未接続'), findsOneWidget);

    final generate = find.widgetWithIcon(IconButton, Icons.auto_awesome);
    await tester.tap(generate);
    await tester.pump();
    expect(find.text('ComfyUIを起動・接続中…'), findsOneWidget);
    expect(tester.widget<IconButton>(generate).onPressed, isNull);

    startup.completeError(StateError('起動タイムアウト'));
    await tester.pumpAndSettle();
    expect(find.textContaining('起動タイムアウト'), findsOneWidget);
    expect(tester.widget<IconButton>(generate).onPressed, isNotNull);

    available = true;
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('ComfyUI 接続済み'), findsOneWidget);
    expect(find.textContaining('起動タイムアウト'), findsOneWidget);

    available = false;
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('ComfyUI 未接続'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
