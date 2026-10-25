import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/models/pdf_page_edit.dart';
import 'package:pdf_viewer/web/web_pdf_page_editor.dart';

class _Client implements PdfPageEditorClient {
  List<Map<String, int>>? saved;
  String? restored;
  bool failSave = false;
  int saveCalls = 0;

  @override
  Future<Map<String, dynamic>> fetchPdfEditInfo(String mediaId) async => {
    'revision': 'original',
    'pageCount': 3,
    'backups': [
      {'id': 'backup-one', 'createdAt': '2026-10-24T00:00:00Z', 'pageCount': 4},
    ],
  };

  @override
  Future<Map<String, dynamic>> savePdfPages(
    String mediaId,
    String revision,
    List<Map<String, int>> pages,
  ) async {
    expect(mediaId, 'pdf-one');
    expect(revision, 'original');
    saveCalls++;
    if (failSave) throw StateError('PDFが変更されています');
    saved = pages;
    return {'revision': 'edited', 'pageCount': pages.length};
  }

  @override
  Future<Map<String, dynamic>> restorePdfBackup(
    String mediaId,
    String revision,
    String backupId,
  ) async {
    expect(revision, 'original');
    restored = backupId;
    return {'revision': 'restored', 'pageCount': 4};
  }

  @override
  Future<Uint8List> fetchThumbnail(
    String mediaId, {
    int? width,
    int? height,
    int? page,
    bool refresh = false,
  }) async {
    return base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
  }
}

Future<void> _open(
  WidgetTester tester,
  _Client client, {
  bool narrow = false,
}) async {
  tester.view.physicalSize = narrow
      ? const Size(360, 800)
      : const Size(1200, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<bool>(
              context: context,
              builder: (_) => WebPdfPageEditor(
                client: client,
                mediaId: 'pdf-one',
                title: '作品.pdf',
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'deletion, rotation and reorder are staged until confirmed save',
    (tester) async {
      final client = _Client();
      await _open(tester, client);
      await tester.tap(find.byTooltip('90度右回転').at(1));
      await tester.pump();
      await tester.tap(find.byTooltip('このページを削除').first);
      await tester.pump();
      await tester.tap(find.byTooltip('前へ移動').at(1));
      await tester.pump();
      expect(client.saved, isNull);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(client.saved, isNull);
      await tester.tap(find.text('実行'));
      await tester.pumpAndSettle();
      expect(client.saved, [
        {'page': 3, 'rotation': 0},
        {'page': 2, 'rotation': 90},
      ]);
      expect(find.byType(WebPdfPageEditor), findsNothing);
    },
  );

  testWidgets('last page cannot be deleted and reset restores all pages', (
    tester,
  ) async {
    final client = _Client();
    await _open(tester, client);
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byTooltip('このページを削除').first);
      await tester.pump();
    }
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == 'このページを削除',
            ),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('編集をリセット'));
    await tester.pump();
    expect(find.byTooltip('このページを削除'), findsNWidgets(3));
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
          .onPressed,
      isNull,
    );
    expect(client.saveCalls, 0);
  });

  testWidgets(
    'conflict leaves edits visible and reload discards staged changes',
    (tester) async {
      final client = _Client()..failSave = true;
      await _open(tester, client);
      await tester.tap(find.byTooltip('90度右回転').first);
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('実行'));
      await tester.pumpAndSettle();
      expect(find.textContaining('PDFが変更されています'), findsOneWidget);
      expect(find.byType(WebPdfPageEditor), findsOneWidget);
      await tester.tap(find.text('変更を破棄して再読み込み'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets('backup restore requires explicit confirmation', (tester) async {
    final client = _Client();
    await _open(tester, client);
    await tester.tap(find.byTooltip('バックアップから復元'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('(4ページ)'));
    await tester.pumpAndSettle();
    expect(client.restored, isNull);
    await tester.tap(find.text('実行'));
    await tester.pumpAndSettle();
    expect(client.restored, 'backup-one');
  });

  testWidgets('editing controls fit a narrow screen and cancel does not save', (
    tester,
  ) async {
    final client = _Client();
    await _open(tester, client, narrow: true);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('90度右回転').first);
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();
    expect(client.saveCalls, 0);
    expect(tester.takeException(), isNull);
  });
}
