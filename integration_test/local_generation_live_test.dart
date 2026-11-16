// Explicit opt-in: creates a real image and uploads it to the configured host.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pdf_viewer/repository/generated_media_repository.dart';
import 'package:pdf_viewer/scene/generation_jobs_page.dart';
import 'package:pdf_viewer/services/app_settings_service.dart';
import 'package:pdf_viewer/services/local_generation_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'generate with local GPU and upload the resulting image',
    (tester) async {
      if (!const bool.fromEnvironment('LIVE_COMFY_TEST')) return;
      final service = LocalGenerationService.instance;
      final token = await service.start();
      final repo = GeneratedMediaRepository(
        LocalGenerationService.baseUrl,
        token,
      );
      addTearDown(repo.close);
      final previous = (await repo.jobs()).map((j) => j['id']).toSet();
      await tester.pumpWidget(
        MaterialApp(home: GenerationJobsPage(repo: repo)),
      );
      Future<void> until(bool Function() done) async {
        final deadline = DateTime.now().add(const Duration(minutes: 3));
        while (!done()) {
          if (DateTime.now().isAfter(deadline))
            fail('Generation screen did not become ready');
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await until(() => find.text('生成する').evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      await tester.tap(find.text('生成する'));
      await tester.pump();
      Map<String, dynamic>? completed;
      final deadline = DateTime.now().add(const Duration(minutes: 15));
      while (completed == null && DateTime.now().isBefore(deadline)) {
        final jobs = await repo.jobs();
        final added = jobs.where((j) => !previous.contains(j['id']));
        if (added.isNotEmpty) {
          final job = added.first;
          if (job['state'] == 'failed')
            fail('Generation failed: ${job['error']}');
          if (job['state'] == 'completed') completed = job;
        }
        await tester.pump(const Duration(seconds: 1));
      }
      expect(completed, isNotNull);
      final id = (completed!['mediaIds'] as List).single as String;
      final image = File('${service.libraryPath}/originals/$id.png');
      expect(await image.exists(), isTrue);
      final settings = await AppSettingsService().loadMetadataSettings();
      expect(settings.isClientMode, isTrue);
      final remote = GeneratedMediaRepository(settings.remoteApiBaseUrl, settings.authToken);
      try {
        await remote.uploadImage(image.path);
      } finally {
        remote.close();
      }
      final report = File('.dart_tool/comfy-setup/live-result.json');
      await report.writeAsString(
        jsonEncode({
          'jobId': completed['id'],
          'imageId': id,
          'localImage': image.path,
          'uploadedCount': 1,
          'hostGallery': 'generated',
          'model': 'waiIllustriousSDXL_v160.safetensors',
        }),
      );
      await tester.pumpWidget(const SizedBox());
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
