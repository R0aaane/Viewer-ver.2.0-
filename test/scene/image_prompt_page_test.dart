import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/repository/image_prompt_repository.dart';
import 'package:pdf_viewer/scene/image_prompt_page.dart';

class _Repository extends ImagePromptRepository {
  _Repository(): super('http://fixture.invalid', 'fixture');
  PromptJson? edit;
  @override
  Future<PromptJson> load(String source,int page) async => {'version': 3,'latestJob':null,'document':{
    'jobId':'completed-job','tags':[
      {'text':'blue eyes','category':'appearance','enabled':true,'sources':['qwen3-vl','wd14'],'confidence':0.9},
      {'text':'standing','category':'pose','enabled':true,'sources':['qwen3-vl'],'confidence':null},
    ],'disabledCategories':<String>[],'warnings':<String>[],
  }};
  @override
  Future<PromptJson> save(PromptJson value) async { edit=value; return {'version':4}; }
}

void main(){
  test('selected prompt deduplicates and respects category and tag switches', () {
    final tags=<PromptJson>[
      {'text':'blue_eyes','category':'appearance','enabled':true},
      {'text':'blue eyes','category':'appearance','enabled':true},
      {'text':'standing','category':'pose','enabled':false},
    ];
    expect(selectedPrompt(tags,{}),'blue eyes');
    expect(selectedPrompt(tags,{'appearance'}),'');
  });
  testWidgets('send selected prompt to generation without copying or saving', (tester) async {
    final repo = _Repository();
    String? received;
    await tester.pumpWidget(MaterialApp(home: ImagePromptPage(source:'pdf',title:'Example PDF',page:2,
      repository:repo,image:() async=>Uint8List(0),openGeneration:(value) async { received = value; })));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(Switch).first);
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('このプロンプトで画像生成'));
    await tester.pumpAndSettle();
    expect(received, 'standing');
    expect(repo.edit, isNull);
    await tester.tap(find.text('結果を保存'));
    await tester.pumpAndSettle();
    expect(repo.edit!['disabledCategories'], contains('appearance'));
    await tester.pumpWidget(const SizedBox());repo.close();
  });

  testWidgets('reopen saved result, disable category and save with expected version', (tester) async {
    final repo=_Repository();
    await tester.pumpWidget(MaterialApp(home:ImagePromptPage(source:'pdf',title:'Example',page:2,
      repository:repo,image:() async=>Uint8List(0))));
    await tester.pumpAndSettle();
    expect(find.text('Example · 2ページ'),findsOneWidget);
    final text=tester.widget<TextField>(find.byType(TextField).first);
    expect(text.controller!.text,'blue eyes, standing');
    await tester.ensureVisible(find.byType(Switch).first);
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(text.controller!.text,'standing');
    await tester.tap(find.text('結果を保存'));
    await tester.pumpAndSettle();
    expect(repo.edit!['expectedVersion'],3);
    expect(repo.edit!['disabledCategories'],contains('appearance'));
    expect(repo.edit!['jobId'],'completed-job');
    await tester.pumpWidget(const SizedBox());repo.close();
  });
}
