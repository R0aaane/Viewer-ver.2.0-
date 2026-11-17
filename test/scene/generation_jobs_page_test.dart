import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pdf_viewer/repository/generated_media_repository.dart';
import 'package:pdf_viewer/scene/generation_jobs_page.dart';

class _Repository extends GeneratedMediaRepository {
  _Repository() : super('http://fixture.invalid', 'test-token');
  final keys = <String>[];
  final requests = <GalleryJson>[];
  bool loseResponse = true;
  int cancellations = 0;
  final row = <String, dynamic>{
    'id': 'job-1',
    'preset': 'fixture',
    'state': 'running',
    'created': 1000,
    'mediaIds': <String>[],
  };

  @override
  Future<List<GalleryJson>> presets() async => [
    {
      'id': 'fixture',
      'name': 'Fixture',
      'parameters': {
        'positive': {'label': 'Positive Prompt', 'type': 'text', 'default': ''},
        'steps': {
          'label': 'Steps',
          'type': 'integer',
          'min': 1,
          'max': 40,
          'default': 20,
        },
      },
    },
  ];

  @override
  Future<List<GalleryJson>> jobs({double? before}) async =>
      keys.isEmpty ? [] : [row];

  @override
  Future<GalleryJson> submitJob(String key, GalleryJson request) async {
    keys.add(key);
    requests.add(request);
    if (loseResponse) {
      throw DioException.connectionError(
        requestOptions: RequestOptions(),
        reason: 'Lost response',
      );
    }
    return row;
  }

  @override
  Future<void> cancelJob(String id) async {
    cancellations++;
    row['state'] = 'cancel_requested';
  }
}

class _PagedRepository extends _Repository {
  bool completed = false;
  final olderRequests = <double>[];

  @override
  Future<List<GalleryJson>> jobs({double? before}) async {
    if (before == null) {
      return List.generate(
        100,
        (index) => {
          'id': 'recent-$index',
          'preset': 'recent-$index',
          'state': 'completed',
          'created': 1000 - index,
          'mediaIds': <String>[],
        },
      );
    }
    olderRequests.add(before);
    return [
      {
        'id': 'older',
        'preset': 'older',
        'state': completed ? 'completed' : 'running',
        'created': 900,
        'mediaIds': <String>[],
      },
    ];
  }
}

class _PresetRepository extends _Repository {
  @override
  Future<List<GalleryJson>> presets() async {
    final base = await super.presets();
    return [...base, {...base.first, 'id': 'lora', 'name': 'LoRA preset'}];
  }
}

class _DeletedThumbnailRepository extends _Repository {
  int loads = 0;
  @override
  Future<List<GalleryJson>> jobs({double? before}) async => List.generate(40, (i) => {
    ...row, 'id': 'history-$i', 'state': 'completed', 'mediaIds': ['deleted-$i'],
  });
  @override
  Future<Uint8List> thumbnail(String id) async {
    loads++;
    throw StateError('Image was deleted');
  }
}

void main() {
  testWidgets('offscreen history does not start unobserved thumbnail requests', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final repo = _DeletedThumbnailRepository();
    addTearDown(repo.close);
    await tester.pumpWidget(MaterialApp(home: GenerationJobsPage(repo: repo)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(repo.loads, lessThan(40));
    await tester.scrollUntilVisible(find.text('生成履歴'), 400, scrollable: find.byType(Scrollable).first);
    await tester.drag(find.byType(ListView).first, const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(repo.loads, greaterThan(0));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('import prompt without submitting and preserve edited prompt across presets', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final repo = _PresetRepository()..loseResponse = false;
    addTearDown(repo.close);
    await tester.pumpWidget(MaterialApp(home: GenerationJobsPage(repo: repo, initialPositivePrompt: 'blue eyes, standing')));
    await tester.pumpAndSettle();
    expect(find.text('blue eyes, standing'), findsOneWidget);
    expect(repo.keys, isEmpty);
    await tester.enterText(find.byType(TextFormField).first, 'edited analysis prompt');
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('LoRA preset').last);
    await tester.pumpAndSettle();
    expect(find.text('edited analysis prompt'), findsOneWidget);
    await tester.tap(find.text('生成する'));
    await tester.pumpAndSettle();
    expect(repo.requests.single['preset'], 'lora');
    expect(repo.requests.single['parameters']['positive'], 'edited analysis prompt');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('handoff does not overwrite an uncertain submission', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final repo = _Repository();
    addTearDown(repo.close);
    await tester.pumpWidget(MaterialApp(home: GenerationJobsPage(repo: repo)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'uncertain original');
    await tester.tap(find.text('生成する'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(MaterialApp(home: GenerationJobsPage(repo: repo, initialPositivePrompt: 'incoming analysis')));
    await tester.pumpAndSettle();
    expect(find.text('uncertain original'), findsOneWidget);
    expect(find.text('incoming analysis'), findsNothing);
    repo.loseResponse = false;
    await tester.tap(find.text('前回の送信を確認・再試行'));
    await tester.pumpAndSettle();
    expect(repo.requests[0], repo.requests[1]);
    expect(find.text('解析プロンプトを適用して、新しい画像を生成できます。'), findsOneWidget);
    await tester.ensureVisible(find.text('解析プロンプトを適用'));
    await tester.tap(find.text('解析プロンプトを適用'));
    await tester.pumpAndSettle();
    expect(find.text('incoming analysis'), findsOneWidget);
    expect(repo.keys, hasLength(2));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reconnect starts the service without submitting another job', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final repo = _Repository();
    var reconnects = 0;
    await tester.pumpWidget(MaterialApp(home: GenerationJobsPage(repo: repo, reconnect: () async { reconnects++; })));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ComfyUIを起動・再接続'));
    await tester.pumpAndSettle();
    expect(reconnects, 1);
    expect(repo.requests, isEmpty);
    await tester.pumpWidget(const SizedBox());
    repo.close();
  });

  testWidgets('polling also refreshes a running job in older loaded history', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final repo = _PagedRepository();
    addTearDown(repo.close);
    await tester.pumpWidget(MaterialApp(home: GenerationJobsPage(repo: repo)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('以前の履歴を読み込む'),
      1000,
        scrollable: find.byType(Scrollable).first,
      maxScrolls: 30,
    );
    await tester.tap(find.text('以前の履歴を読み込む'));
    await tester.pumpAndSettle();
    expect(find.text('実行中 · older'), findsOneWidget);
    repo.completed = true;
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('完了 · older'), findsOneWidget);
    expect(repo.olderRequests.length, greaterThanOrEqualTo(2));
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'validate settings and recover the same request after reopening',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final repo = _Repository();
      addTearDown(repo.close);
      Future<void> open() async {
        await tester.pumpWidget(
          MaterialApp(home: GenerationJobsPage(repo: repo)),
        );
        await tester.pumpAndSettle();
      }

      await open();
      await tester.enterText(find.byType(TextFormField).at(1), '0');
      await tester.tap(find.text('生成する'));
      await tester.pumpAndSettle();
      expect(repo.keys, isEmpty);
      expect(find.text('1〜40で入力してください'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField).at(1), '25');
      await tester.enterText(find.byType(TextFormField).first, 'saved prompt');
      await tester.tap(find.text('生成する'));
      await tester.pumpAndSettle();
      expect(repo.keys, hasLength(1));
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('通信または保存に失敗しました。更新して再試行してください'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await open();
      expect(find.text('前回の送信を確認・再試行'), findsOneWidget);
      expect(find.text('saved prompt'), findsOneWidget);
      repo.loseResponse = false;
      await tester.tap(find.text('前回の送信を確認・再試行'));
      await tester.pumpAndSettle();
      expect(repo.keys, hasLength(2));
      expect(repo.keys[0], repo.keys[1]);
      expect(repo.requests[0], repo.requests[1]);
      expect(repo.requests[1]['parameters'], {
        'positive': 'saved prompt',
        'steps': 25,
      });
      expect(find.text('生成する'), findsOneWidget);
      await tester.scrollUntilVisible(find.byTooltip('生成をキャンセル'), 250,
          scrollable: find.byType(Scrollable).first);
      await tester.ensureVisible(find.byTooltip('生成をキャンセル'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('生成をキャンセル'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('キャンセルする'));
      await tester.pumpAndSettle();
      expect(repo.cancellations, 1);
      expect(find.textContaining('キャンセル待ち'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
