import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pdf_viewer/models/metadata_settings.dart';
import 'package:pdf_viewer/repository/generated_media_repository.dart';
import 'package:pdf_viewer/scene/generated_gallery_page.dart';

Map<String, dynamic> summary(List<double> samples) {
  final sorted = [...samples]..sort();
  if (sorted.isEmpty) return {'n': 0};
  return {
    'n': sorted.length,
    'p50_ms': sorted[sorted.length ~/ 2],
    'p95_ms':
        sorted[((sorted.length * .95).ceil() - 1).clamp(0, sorted.length - 1)],
    'max_ms': sorted.last,
  };
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'measure the actual generated gallery against the marked 30k fixture',
    (tester) async {
      const controlPath = String.fromEnvironment('BENCH_CONTROL_PATH');
      expect(controlPath.isNotEmpty, isTrue);
      final control = jsonDecode(await File(controlPath).readAsString()) as Map;
      final baseUrl = control['baseUrl'] as String;
      final token = control['token'] as String;
      final expectedCount = control['catalogCount'] as int;
      final prefs = await SharedPreferences.getInstance();
      final cursorKey =
          'generated.sync.${remoteSourceId('$baseUrl/generated', 'Bearer $token')}';
      await prefs.remove(cursorKey);
      addTearDown(() => prefs.remove(cursorKey));
      final nextPage = find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == '次のページ',
      );
      const pageLimit = int.fromEnvironment(
        'BENCH_PAGE_LIMIT',
        defaultValue: 1000,
      );
      final imageCache = PaintingBinding.instance.imageCache;
      final rssBefore = ProcessInfo.currentRss;
      var peakRss = rssBefore;
      var peakDecoded = 0;
      var peakCompressed = 0;
      GeneratedMediaRepository? repository;
      final checkpoints = <Map<String, dynamic>>[];
      void sample() {
        final current = ProcessInfo.currentRss;
        if (current > peakRss) peakRss = current;
        if (imageCache.currentSizeBytes > peakDecoded) {
          peakDecoded = imageCache.currentSizeBytes;
        }
        final compressed = repository?.cachedBytes ?? 0;
        if (compressed > peakCompressed) peakCompressed = compressed;
      }

      final memoryTimer = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => sample(),
      );
      addTearDown(memoryTimer.cancel);
      Future<Map> counters() async {
        final client = HttpClient();
        try {
          final request = await client.getUrl(
            Uri.parse('$baseUrl/performance/counters'),
          );
          request.headers.set('Authorization', 'Bearer $token');
          final response = await request.close();
          expect(response.statusCode, 200);
          return jsonDecode(await utf8.decoder.bind(response).join()) as Map;
        } finally {
          client.close(force: true);
        }
      }

      Future<void> until(bool Function() condition) async {
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (!condition()) {
          if (DateTime.now().isAfter(deadline)) {
            fail('Gallery did not settle within 30 seconds');
          }
          await tester.pump(const Duration(milliseconds: 16));
        }
      }

      bool firstImage() => tester
          .widgetList<RawImage>(find.byType(RawImage))
          .any((image) => image.image != null);
      Future<void> settleImages() async {
        await until(() {
          final tiles = find.byType(GridTile).evaluate().length;
          final decoded = tester
              .widgetList<RawImage>(find.byType(RawImage))
              .where((image) => image.image != null)
              .length;
          return tiles > 0 && decoded >= tiles;
        });
        await tester.pump();
        expect(find.byTooltip('サムネイルを再取得'), findsNothing);
        sample();
        expect(
          repository!.cachedBytes,
          lessThanOrEqualTo(repository.thumbnailBudget),
        );
        expect(
          imageCache.currentSizeBytes,
          lessThanOrEqualTo(imageCache.maximumSizeBytes),
        );
      }

      final serverBefore = await counters();
      final cold = Stopwatch()..start();
      await tester.pumpWidget(
        MaterialApp(
          home: GeneratedGalleryPage(baseUrl: baseUrl, token: token),
        ),
      );
      await until(firstImage);
      await tester.pump();
      final coldFirstMs = cold.elapsedMicroseconds / 1000;
      final dynamic state = tester.state(find.byType(GeneratedGalleryPage));
      repository = state.repo as GeneratedMediaRepository;
      await settleImages();

      final sync = Stopwatch()..start();
      while (true) {
        await repository.synchronize();
        await prefs.reload();
        final raw = prefs.getString(cursorKey);
        if (raw != null &&
            (jsonDecode(raw)['cursor'] as int) >=
                (control['syncHead'] as int)) {
          break;
        }
        if (sync.elapsed > const Duration(minutes: 3)) {
          fail('Initial delta backlog did not drain');
        }
        await tester.pump(const Duration(milliseconds: 50));
      }
      sync.stop();
      await settleImages();

      final buildSamples = <double>[];
      final rasterSamples = <double>[];
      void frameTimings(List<FrameTiming> timings) {
        for (final timing in timings) {
          buildSamples.add(timing.buildDuration.inMicroseconds / 1000);
          rasterSamples.add(timing.rasterDuration.inMicroseconds / 1000);
        }
      }

      WidgetsBinding.instance.addTimingsCallback(frameTimings);
      addTearDown(
        () => WidgetsBinding.instance.removeTimingsCallback(frameTimings),
      );
      final pages = <double>[];
      final firstThumbnails = <double>[];
      final browsing = Stopwatch()..start();
      var visited = 0;
      while (visited < pageLimit) {
        final pageClock = Stopwatch()..start();
        if (visited > 0) {
          await tester.tap(nextPage);
          await tester.pump();
          await until(firstImage);
          await tester.pump();
          firstThumbnails.add(pageClock.elapsedMicroseconds / 1000);
        }
        await settleImages();
        final scroll = tester.state<ScrollableState>(
          find
              .descendant(
                of: find.byType(GridView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        final maximum = scroll.position.maxScrollExtent;
        for (final position in [maximum / 2, maximum]) {
          scroll.position.jumpTo(position);
          await tester.pump();
          await settleImages();
        }
        if (visited % 25 == 0 && maximum > 0) {
          await tester.fling(find.byType(GridView), const Offset(0, 300), 800);
          await tester.pumpAndSettle();
          await settleImages();
        }
        pages.add(pageClock.elapsedMicroseconds / 1000);
        visited++;
        if (visited % 50 == 0) {
          checkpoints.add({
            'pages': visited,
            'rss_mib': ProcessInfo.currentRss / 1048576,
            'decoded_mib': imageCache.currentSizeBytes / 1048576,
            'compressed_mib': repository.cachedBytes / 1048576,
          });
          // No credentials or image metadata are included in diagnostic output.
          // ignore: avoid_print
          print(
            'gallery benchmark pages=$visited rssMiB=${(ProcessInfo.currentRss / 1048576).toStringAsFixed(1)}',
          );
        }
        if (tester.widget<IconButton>(nextPage).onPressed == null) {
          break;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final serverAfter = await counters();
      final report = <String, dynamic>{
        'mode': kProfileMode
            ? 'profile'
            : kReleaseMode
            ? 'release'
            : 'debug',
        'catalog_records': expectedCount,
        'pages_visited': visited,
        'full_catalog_browsed': visited >= (expectedCount / 48).ceil(),
        'browsing_seconds': browsing.elapsedMicroseconds / 1000000,
        'cold_first_thumbnail_ms': coldFirstMs,
        'initial_delta_drain_ms': sync.elapsedMicroseconds / 1000,
        'navigation_first_thumbnail': summary(firstThumbnails),
        'page_top_middle_bottom': summary(pages),
        'build_frames': summary(buildSamples),
        'raster_frames': summary(rasterSamples),
        'rss_before_mib': rssBefore / 1048576,
        'rss_peak_sampled_mib': peakRss / 1048576,
        'rss_peak_os_mib': ProcessInfo.maxRss / 1048576,
        'rss_after_mib': ProcessInfo.currentRss / 1048576,
        'decoded_cache_peak_mib': peakDecoded / 1048576,
        'compressed_cache_peak_mib': peakCompressed / 1048576,
        'decoded_cache_limit_mib': imageCache.maximumSizeBytes / 1048576,
        'compressed_cache_limit_mib': repository.thumbnailBudget / 1048576,
        'viewport_physical': [
          tester.view.physicalSize.width,
          tester.view.physicalSize.height,
        ],
        'device_pixel_ratio': tester.view.devicePixelRatio,
        'memory_checkpoints': checkpoints,
        'server_before': serverBefore,
        'server_after': serverAfter,
      };
      await File(control['reportPath'] as String).writeAsString(
        const JsonEncoder.withIndent('  ').convert(report),
        flush: true,
      );
      await tester.pumpWidget(const SizedBox());
      imageCache.clear();
      imageCache.clearLiveImages();
      expect(tester.takeException(), isNull);
      await File(control['stopPath'] as String).writeAsString('completed');
    },
    timeout: const Timeout(Duration(minutes: 45)),
  );
}
