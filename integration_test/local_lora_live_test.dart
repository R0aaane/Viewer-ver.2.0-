// Explicit opt-in: generate one local image using an installed LoRA.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pdf_viewer/repository/generated_media_repository.dart';
import 'package:pdf_viewer/services/local_generation_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('local LoRA generation preserves workflow and metadata', (tester) async {
    if (!const bool.fromEnvironment('LIVE_LORA_TEST')) return;
    final service = LocalGenerationService.instance;
    final token = await service.start();
    final repo = GeneratedMediaRepository(LocalGenerationService.baseUrl, token);
    addTearDown(repo.close);
    final presets = await repo.presets();
    final preset = presets.firstWhere((p) => p['id'] == 'local-txt2img-lora');
    final choices = preset['parameters']['lora_name']['choices'] as List;
    final lora = choices.firstWhere((n) => (n as String).contains('Flanvia_Style_IL')) as String;
    final job = await repo.submitJob('live-lora-${DateTime.now().microsecondsSinceEpoch}', {
      'preset': preset['id'],
      'parameters': {'lora_name': lora, 'lora_strength_model': 0.5, 'lora_strength_clip': 0.5,
        'positive': 'masterpiece, best quality, landscape, sunny flower garden, no humans',
        'negative': 'low quality, blurry, text, watermark, person', 'steps': 12},
    });
    final deadline = DateTime.now().add(const Duration(minutes: 12));
    Map<String, dynamic>? completed;
    while (DateTime.now().isBefore(deadline)) {
      final current = (await repo.jobs()).firstWhere((j) => j['id'] == job['id']);
      if (current['state'] == 'failed') fail('${current['error']}');
      if (current['state'] == 'completed') { completed = current; break; }
      await tester.pump(const Duration(seconds: 1));
    }
    expect(completed, isNotNull);
    final id = (completed!['mediaIds'] as List).single as String;
    final detail = await repo.detail(id);
    expect((detail['generation']['samplers'] as List).any((s) => (s['lora'] as List).any((l) => l['lora_name'] == lora)), isTrue);
    final image = File('${service.libraryPath}/originals/$id.png');
    expect(await image.exists(), isTrue);
    await File('.dart_tool/comfy-setup/lora-result.json').writeAsString(jsonEncode({
      'jobId': job['id'], 'imageId': id, 'lora': lora, 'localImage': image.path,
    }));
  }, timeout: const Timeout(Duration(minutes: 15)));
}
