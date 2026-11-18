import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const captureUiReview = bool.fromEnvironment('UI_CAPTURE');

Future<void> loadUiReviewFonts(WidgetTester tester) async {
  if (!captureUiReview) return;
  await tester.runAsync(() async {
    final bytes = await File('C:/Windows/Fonts/meiryo.ttc').readAsBytes();
    await (FontLoader(
      'ReviewFont',
    )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
}

Future<void> saveUiReview(
  WidgetTester tester,
  GlobalKey key,
  String name,
) async {
  if (!captureUiReview) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/ui_review/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}
