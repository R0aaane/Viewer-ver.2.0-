import 'dart:async';
import 'support/ui_review_capture.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/app/app_theme.dart';
import 'package:pdf_viewer/models/mediaItem.dart';
import 'package:pdf_viewer/models/tag.dart';
import 'package:pdf_viewer/models/tag_with_id.dart';
import 'package:pdf_viewer/scene/widgets/library_inspector.dart';
import 'package:pdf_viewer/scene/widgets/reading_resume_card.dart';

const _item = MediaItem(
  id: 'one',
  displayName: 'Travel.pdf',
  kind: MediaKind.pdf,
  folderRaw: 'Library',
  sizeBytes: 2048,
);
const _tag = TagWithId(
  tagId: 1,
  tag: Tag(name: 'Travel', category: TagCategory.series),
);

void main() {
  testWidgets(
    'inspector loads once, refreshes after editing, and retries errors',
    (tester) async {
      var loads = 0;
      var edits = 0;
      var tags = <TagWithId>[];
      Widget pane() => MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: LibraryInspector(
            item: _item,
            folderLabel: 'Library',
            preview: const Placeholder(),
            loadTags: () async {
              loads++;
              return tags;
            },
            onEditTags: () async {
              edits++;
              tags = [_tag];
            },
            onOpen: () async {},
            onClose: () {},
          ),
        ),
      );
      await tester.pumpWidget(pane());
      await tester.pumpAndSettle();
      expect(loads, 1);
      await tester.pumpWidget(pane());
      await tester.pump();
      expect(loads, 1);
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pumpAndSettle();
      await tester.tap(find.text('追加'));
      await tester.pumpAndSettle();
      expect(edits, 1);
      expect(loads, 2);
      expect(find.widgetWithText(Chip, 'Travel'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('late tags from another item cannot replace the current item', (
    tester,
  ) async {
    final first = Completer<List<TagWithId>>();
    final second = Completer<List<TagWithId>>();
    Widget pane(MediaItem item, Future<List<TagWithId>> result) => MaterialApp(
      home: Scaffold(
        body: LibraryInspector(
          item: item,
          folderLabel: 'Library',
          preview: const Placeholder(),
          loadTags: () => result,
          onOpen: () async {},
          onEditTags: () async {},
          onClose: () {},
        ),
      ),
    );
    await tester.pumpWidget(pane(_item, first.future));
    await tester.pumpWidget(
      pane(
        const MediaItem(
          id: 'two',
          displayName: 'Second.pdf',
          kind: MediaKind.pdf,
          folderRaw: 'Library',
        ),
        second.future,
      ),
    );
    first.complete([_tag]);
    second.complete([]);
    await tester.pumpAndSettle();
    expect(find.text('Travel'), findsNothing);
    expect(find.text('Second'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tag errors expose retry and remain distinct from empty tags', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LibraryInspector(
            item: _item,
            folderLabel: 'Library',
            preview: const Placeholder(),
            loadTags: () async {
              if (++calls == 1) throw StateError('offline');
              return [];
            },
            onOpen: () async {},
            onEditTags: () async {},
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    await tester.tap(find.text('再試行'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('タグはまだ付いていません。'), findsOneWidget);
  });

  for (final width in [320.0, 380.0]) {
    testWidgets('inspector fits width $width with enlarged text', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await loadUiReviewFonts(tester);
      final key = GlobalKey();
      var closed = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(
            fontFamily: captureUiReview ? 'ReviewFont' : null,
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: RepaintBoundary(
            key: key,
            child: Scaffold(
              body: LibraryInspector(
                item: _item,
                folderLabel: 'Library / Travel / 2026',
                preview: const ColoredBox(color: Color(0xFF536C79)),
                loadTags: () async => [_tag],
                onOpen: () async {},
                onEditTags: () async {},
                onClose: () => closed = true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await saveUiReview(tester, key, 'inspector_${width.toInt()}_2x');
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('詳細を閉じる'));
      expect(closed, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [320.0, 380.0, 1000.0]) {
    testWidgets('resume card preserves callback at $width with large text', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await loadUiReviewFonts(tester);
      final reviewKey = GlobalKey();
      var page = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(
            fontFamily: captureUiReview ? 'ReviewFont' : null,
          ),
          builder: (_, child) => RepaintBoundary(key: reviewKey, child: child!),
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 900),
              textScaler: const TextScaler.linear(2),
            ),
            child: Scaffold(
              body: SingleChildScrollView(
                child: ReadingResumeCard(
                  title: 'Long travel journal title',
                  preview: const Placeholder(),
                  progress: .42,
                  pageLabel: 'p.42 / 100',
                  description: 'Author · Series',
                  onResume: () => page = 42,
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byType(FilledButton));
      await tester.tap(find.byType(FilledButton));
      expect(page, 42);
      await tester.pumpAndSettle();
      await saveUiReview(tester, reviewKey, 'resume_${width.toInt()}_2x');
    });
  }
}
