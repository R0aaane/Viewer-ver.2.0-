import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/app/app_theme.dart';
import 'package:pdf_viewer/scene/widgets/library_media_card.dart';
import 'package:pdf_viewer/scene/widgets/library_view_controls.dart';

void main() {
  testWidgets('query chips remove one token and preserve the other syntax', (
    tester,
  ) async {
    var query = 'artist:Alice #travel #travel';
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SizedBox(
              height: 48,
              child: LibraryQueryChips(
                query: query,
                onChanged: (value) => setState(() => query = value),
                onClearAll: () => setState(() => query = ''),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('この検索条件を解除').at(1));
    await tester.pumpAndSettle();
    expect(query, 'artist:Alice #travel');
    await tester.tap(find.text('全解除'));
    await tester.pumpAndSettle();
    expect(query, isEmpty);
    expect(tester.takeException(), isNull);
  });

  if (const bool.fromEnvironment('UI_CAPTURE')) {
    for (final width in [390.0, 1280.0]) {
      testWidgets('capture library components at $width', (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.runAsync(() async {
          final bytes = await File('C:/Windows/Fonts/meiryo.ttc').readAsBytes();
          final loader = FontLoader('ReviewFont')..addFont(Future.value(ByteData.sublistView(bytes)));
          await loader.load();
          final icons = FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
          await icons.load();
        });
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(fontFamily: 'ReviewFont'),
            home: RepaintBoundary(
              key: key,
              child: Scaffold(
                appBar: AppBar(title: const Text('ライブラリ · UI部品レビュー')),
                body: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: TextField(
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          hintText: 'タイトル・作者・タグを検索',
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        const SizedBox(width: 16),
                        const Text('12 件'),
                        const Spacer(),
                        LibraryViewControls(
                          listView: false,
                          largeCovers: false,
                          cropCovers: false,
                          onListViewChanged: (_) {},
                          onLargeCoversChanged: (_) {},
                          onCropCoversChanged: (_) {},
                        ),
                      ],
                    ),
                    Expanded(
                      child: GridView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: 12,
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 240,
                              mainAxisSpacing: 16,
                              crossAxisSpacing: 16,
                              childAspectRatio: 0.65,
                            ),
                        itemBuilder: (_, index) => LibraryMediaCard(
                          title: [
                            '旅の記録',
                            '静かな暮らし',
                            '建築と光',
                            '風景のかたち',
                          ][index % 4],
                          subtitle: index.isEven ? 'PDF' : '画像',
                          selected: index == 1,
                          onToggleFavorite: () {},
                          isFavorite: index == 2,
                          menu: IconButton(
                            onPressed: () {},
                            icon: const Icon(Icons.more_vert),
                          ),
                          preview: ColoredBox(
                            color: [
                              const Color(0xFF536C79),
                              const Color(0xFFB8AA90),
                              const Color(0xFF6E7471),
                              const Color(0xFF515976),
                            ][index % 4],
                            child: Center(
                              child: Icon(
                                [
                                  Icons.landscape_outlined,
                                  Icons.spa_outlined,
                                  Icons.architecture,
                                  Icons.waves,
                                ][index % 4],
                                size: 72,
                                color: Colors.white70,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            'build/ui_review/library_components_${width.toInt()}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      });
    }
  }

  for (final width in [320.0, 600.0, 1280.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('cards and view controls at width $width text $scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var list = false;
        var large = false;
        var crop = false;
        var favorite = false;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: StatefulBuilder(
              builder: (context, setState) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: true,
                ),
                child: Scaffold(
                  body: Column(
                    children: [
                      LibraryViewControls(
                        listView: list,
                        largeCovers: large,
                        cropCovers: crop,
                        onListViewChanged: (value) =>
                            setState(() => list = value),
                        onLargeCoversChanged: (value) =>
                            setState(() => large = value),
                        onCropCoversChanged: (value) =>
                            setState(() => crop = value),
                      ),
                      SizedBox(
                        width: list ? width - 24 : 148,
                        height: list ? 180 : 250,
                        child: LibraryMediaCard(
                          title: 'Travel journal — long title',
                          subtitle: 'PDF',
                          listView: list,
                          selected: true,
                          isFavorite: favorite,
                          onToggleFavorite: () =>
                              setState(() => favorite = !favorite),
                          menu: IconButton(
                            tooltip: 'メニュー',
                            onPressed: () {},
                            icon: const Icon(Icons.more_vert),
                          ),
                          preview: const ColoredBox(
                            color: Color(0xFF354B63),
                            child: Center(
                              child: Icon(Icons.landscape_outlined, size: 48),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('お気に入りに追加'));
        await tester.pump();
        expect(favorite, isTrue);
        await tester.tap(find.byTooltip('リスト表示'));
        await tester.pump();
        expect(list, isTrue);
        expect(tester.takeException(), isNull);
        expect(
          tester
              .widget<AnimatedContainer>(find.byType(AnimatedContainer).first)
              .duration,
          Duration.zero,
        );
        await tester.tap(find.byTooltip('表示オプション'));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(CheckedPopupMenuItem<String>).first);
        await tester.pumpAndSettle();
        expect(large, isTrue);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
