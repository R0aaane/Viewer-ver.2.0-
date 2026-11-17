// Explicit opt-in: reuse a saved PDF analysis and hand off to the real local form.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pdf_viewer/repository/generated_media_repository.dart';
import 'package:pdf_viewer/repository/image_prompt_repository.dart';
import 'package:pdf_viewer/scene/image_prompt_page.dart';
import 'package:pdf_viewer/scene/generation_jobs_page.dart';
import 'package:pdf_viewer/services/image_prompt_host_service.dart';
import 'package:pdf_viewer/services/local_generation_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('saved PDF prompt opens local ComfyUI form without automatic submission', (tester) async {
    if (!const bool.fromEnvironment('LIVE_PROMPT_HANDOFF')) return;
    final fixture=jsonDecode(await File('.dart_tool/image-prompt/live-result.json').readAsString()) as Map;
    final token=await ImagePromptHostService.instance.start();
    final repo=ImagePromptRepository(ImagePromptHostService.baseUrl,token);
    addTearDown(repo.close);
    final saved=await repo.load(fixture['source'] as String,1);
    final expected=saved['document']['prompt'] as String;
    expect(expected,isNotEmpty);
    final generationToken=await LocalGenerationService.instance.start();
    final generation=GeneratedMediaRepository(LocalGenerationService.baseUrl,generationToken);
    addTearDown(generation.close);
    final before=(await generation.jobs()).map((j)=>j['id']).toList();
    await tester.pumpWidget(MaterialApp(home:ImagePromptPage(source:fixture['source'],title:'PDF handoff test',page:1,
      repository:repo,image:() async=>throw StateError('Saved analysis must not render again'))));
    Future<void> until(bool Function() ready) async {
      final deadline=DateTime.now().add(const Duration(minutes:3));
      while(!ready()) {
        if(DateTime.now().isAfter(deadline)) fail('Handoff screen did not become ready');
        await tester.pump(const Duration(milliseconds:200));
      }
    }
    await until(()=>find.text('このプロンプトで画像生成').evaluate().isNotEmpty && find.byType(LinearProgressIndicator).evaluate().isEmpty);
    await tester.tap(find.text('このプロンプトで画像生成'));
    await until(()=>find.byType(GenerationJobsPage).evaluate().isNotEmpty && find.text(expected).evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(GenerationJobsPage), matching: find.text(expected)),findsOneWidget);
    expect((await generation.jobs()).map((j)=>j['id']).toList(),before);
    await File('.dart_tool/image-prompt/handoff-live-result.json').writeAsString(jsonEncode({'source':fixture['source'],
      'promptCharacters':expected.length,'inputMatched':true,'noAutomaticSubmission':true}));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  },timeout:const Timeout(Duration(minutes:5)));
}
