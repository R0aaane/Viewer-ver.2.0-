// Explicit opt-in: render a PDF page, run both local models, edit and persist.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pdf_viewer/models/mediaItem.dart';
import 'package:pdf_viewer/repository/folderRepository.dart';
import 'package:pdf_viewer/repository/image_prompt_repository.dart';
import 'package:pdf_viewer/scene/image_prompt_page.dart';
import 'package:pdf_viewer/services/image_prompt_host_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('PDF image to prompt with real Qwen3-VL and WD14', (tester) async {
    if (!const bool.fromEnvironment('LIVE_IMAGE_PROMPT_TEST')) return;
    final token = await ImagePromptHostService.instance.start();
    final repo = ImagePromptRepository(ImagePromptHostService.baseUrl, token);
    addTearDown(repo.close);
    final file = File('.dart_tool/image-prompt/fixture.pdf').absolute;
    final item = MediaItem(id: file.path, displayName: 'Image to Prompt test PDF', kind: MediaKind.pdf, folderRaw: file.parent.path);
    final source = 'live-pdf-${DateTime.now().microsecondsSinceEpoch}';
    await tester.pumpWidget(MaterialApp(home: ImagePromptPage(source: source, title: item.displayName, page: 1,
      repository: repo, image: () => WindowsFolderRepository().renderStaticPageBytes(item, 1, maxWidth: 1280))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('この画像を解析'));
    await tester.pump();
    final deadline = DateTime.now().add(const Duration(minutes: 14));
    Map<String,dynamic>? completed;
    while (DateTime.now().isBefore(deadline)) {
      final saved = await repo.load(source, 1);
      final job = saved['latestJob'];
      if (job?['state'] == 'failed') fail('${job['error']}');
      if (job?['state'] == 'completed') { completed = Map<String,dynamic>.from(job); break; }
      await tester.pump(const Duration(seconds: 1));
    }
    expect(completed, isNotNull);
    expect(completed!['result']['raw']['qwen'], isNotEmpty);
    expect(completed['result']['raw']['wd14'], isNotEmpty);
    // Let the screen's next poll apply the completed proposal.
    for (var i=0; i<5; i++) { await tester.pump(const Duration(seconds: 1)); }
    expect(find.text('未保存の変更があります'), findsOneWidget);
    await tester.tap(find.text('結果を保存'));
    await tester.pumpAndSettle();
    final saved = await repo.load(source, 1);
    expect(saved['version'], 1);
    expect(saved['document']['prompt'], isNotEmpty);
    await File('.dart_tool/image-prompt/live-result.json').writeAsString(jsonEncode({
      'source':source, 'jobId':completed['id'], 'tagCount':(saved['document']['tags'] as List).length,
      'models':saved['document']['models'], 'version':saved['version'],
    }));
    await tester.pumpWidget(const SizedBox());
  }, timeout: const Timeout(Duration(minutes: 18)));
}
