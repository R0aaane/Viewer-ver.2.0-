import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:integration_test/integration_test.dart';
import 'package:pdf_viewer/scene/generated_gallery_page.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('browse, bulk tag, and reanalyze from the gallery', (
    tester,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final png = im.encodePng(im.Image(width: 4, height: 6));
    final tags = <dynamic>[];
    var reparsed = false;
    var otherDeviceEdited = false;
    var displayName = 'fixture.png';
    var version = 1;
    var deleted = false;
    final submittedVersions = <dynamic>[];
    final calls = <String>[];
    server.listen((request) async {
      final path = request.uri.path;
      calls.add(path);
      final res = request.response;
      if (request.headers.value('Authorization') != 'Bearer fixture') {
        res.statusCode = 401;
      } else if (path.endsWith('thumbnail')) {
        res.headers.contentType = ContentType('image', 'png');
        res.add(png);
      } else {
        res.headers.contentType = ContentType.json;
        if (path == '/generated/changes') {
          res.write(
            '{"epoch":"fixture-epoch","cursor":0,"items":[],"hasMore":false,"resetRequired":false}',
          );
        } else if (path == '/generated/events') {
          res.write('{"items":[]}');
        } else if (path == '/generated/search') {
          res.write(
            jsonEncode({
              'items': [
                {
                  'mediaId': 'sample',
                  'name': displayName,
                  'version': version,
                  'epoch': 'fixture-epoch',
                  'favorite': 0,
                  'tagVersion': tags.length,
                },
              ],
              'hasMore': false,
            }),
          );
        } else if (path == '/generated/tags') {
          final edit = jsonDecode(await utf8.decoder.bind(request).join());
          submittedVersions.add(edit['expected_versions']);
          if (otherDeviceEdited) {
            tags.add({'name': '別端末', 'category': 'free'});
            res.statusCode = 409;
          } else {
            tags.add(edit['tag']);
          }
          res.write('{}');
        } else if (request.method == 'PATCH' &&
            path == '/generated/media/sample') {
          final edit = jsonDecode(await utf8.decoder.bind(request).join());
          if (edit['expected_version'] != version ||
              request.headers.value('X-Sync-Epoch') != 'fixture-epoch') {
            res.statusCode = 409;
          } else {
            displayName = edit['name'] ?? displayName;
            deleted = edit['deleted'] ?? deleted;
            version++;
          }
          res.write('{}');
        } else if (path.endsWith('details') || path.endsWith('reanalyze')) {
          if (path.endsWith('reanalyze')) reparsed = true;
          res.write(
            jsonEncode({
              'name': displayName,
              'version': version,
              'epoch': 'fixture-epoch',
              'deleted': deleted,
              'fileTimeMs': 0,
              'tags': tags,
              'tagVersion': tags.length,
              'generation': {
                'dimensions': [4, 6],
                'samplers': [],
              },
            }),
          );
        } else {
          res.statusCode = 404;
        }
      }
      await res.close();
    });
    Future<void> until(bool Function() predicate) async {
      final end = DateTime.now().add(const Duration(seconds: 15));
      while (!predicate()) {
        if (DateTime.now().isAfter(end)) fail('Timed out: $calls');
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.pumpWidget(
      MaterialApp(
        home: GeneratedGalleryPage(
          baseUrl: 'http://127.0.0.1:${server.port}',
          token: 'fixture',
        ),
      ),
    );
    await until(() => find.text('fixture.png').evaluate().isNotEmpty);
    expect(find.text('接続済み'), findsOneWidget);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('選択した画像のタグを編集'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '保持',
    );
    await tester.pumpAndSettle();
    final apply = find.widgetWithText(FilledButton, '付与');
    expect(tester.widget<FilledButton>(apply).onPressed, isNotNull);
    await tester.tap(apply);
    await until(
      () =>
          tags.isNotEmpty &&
          find.text('fixture.png').evaluate().isNotEmpty &&
          find.byType(AlertDialog).evaluate().isEmpty,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('fixture.png'));
    await until(() => find.text('手動タグ · 保持').evaluate().isNotEmpty);
    await tester.ensureVisible(find.text('生成情報を再解析'));
    await tester.tap(find.text('生成情報を再解析'));
    await until(() => reparsed && find.text('手動タグ · 保持').evaluate().isNotEmpty);
    otherDeviceEdited = true;
    await tester.tap(find.byTooltip('タグ編集'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '競合した編集',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '付与'));
    await until(() => find.text('手動タグ · 別端末').evaluate().isNotEmpty);
    expect(find.textContaining('別の端末でタグが更新'), findsOneWidget);
    expect(tags.any((t) => t['name'] == '競合した編集'), isFalse);
    expect(submittedVersions, [
      {'sample': 0},
      {'sample': 1},
    ]);
    await tester.tap(find.byTooltip('画像の操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('表示名を変更'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'renamed.png',
    );
    await tester.tap(find.text('保存'));
    await until(
      () =>
          displayName == 'renamed.png' &&
          find.text('renamed.png').evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('画像の操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('削除済みに移動'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('実行'));
    await until(() => deleted && find.byTooltip('画像の操作').evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('画像の操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('復元'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('実行'));
    await until(() => !deleted && find.text('手動タグ · 保持').evaluate().isNotEmpty);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await until(() => find.byTooltip('更新').evaluate().isNotEmpty);
    await server.close(force: true);
    await tester.tap(find.byTooltip('更新'));
    await until(() => find.text('オフライン').evaluate().isNotEmpty);
  });
}
