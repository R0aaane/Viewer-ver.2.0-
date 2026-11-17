import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../repository/image_prompt_repository.dart';
import '../services/image_prompt_host_service.dart';
import '../services/local_generation_service.dart';
import '../repository/generated_media_repository.dart';
import 'generation_jobs_page.dart';

const promptCategories = {
  'appearance': '容姿', 'clothing': '服装', 'expression': '表情', 'pose': 'ポーズ',
  'composition': '構図', 'background': '背景', 'style': '画風', 'character': 'キャラクター',
  'other': 'その他', 'rating': 'レーティング',
};
const _stages = {'waiting_gpu': '画像生成が終わるまでGPUを待機中', 'waiting_comfy': 'ComfyUIの生成完了を待機中', 'freeing_comfy': 'ComfyUIのモデルをGPUから解放中', 'unloading_qwen': 'QwenをGPUから解放中', 'queued': '解析待機中', 'loading_qwen': 'Qwen3-VL 8Bを読み込み中',
  'analyzing_qwen': 'Qwen3-VLで特徴を解析中', 'loading_wd14': 'WD14モデルを読み込み中',
  'analyzing_wd14': 'WD14でタグと信頼度を推定中', 'merging': 'タグを統合中',
  'completed': '解析完了', 'failed': '解析失敗', 'interrupted': '解析が中断されました'};

String selectedPrompt(List<PromptJson> tags, Set<String> disabled) {
  final seen = <String>{};
  final result = <String>[];
  for (final category in promptCategories.keys) {
    for (final tag in tags) {
      final text = (tag['text'] as String).trim();
      final key = text.replaceAll(RegExp(r'[_\s]+'), ' ').toLowerCase();
      if (tag['category'] == category && tag['enabled'] != false && !disabled.contains(category) && seen.add(key)) {
        result.add(text.replaceAll('_', ' '));
      }
    }
  }
  return result.join(', ');
}

class ImagePromptPage extends StatefulWidget {
  final String source;
  final String title;
  final int page;
  final Future<Uint8List> Function() image;
  final ImagePromptRepository? repository;
  final Future<void> Function(String)? openGeneration;
  const ImagePromptPage({super.key, required this.source, required this.title, required this.page, required this.image, this.repository, this.openGeneration});
  @override
  State<ImagePromptPage> createState() => _ImagePromptPageState();
}

class _ImagePromptPageState extends State<ImagePromptPage> {
  ImagePromptRepository? repo;
  List<PromptJson> tags = [];
  Set<String> disabled = {'rating'};
  List<String> warnings = [];
  Uint8List? preview;
  String? error, jobId, stage;
  bool loading = true, analyzing = false, saving = false, dirty = false;
  bool openingGeneration = false;
  int version = 0;
  double? analysisSeconds;
  String? execution;
  bool _polling = false;
  Timer? timer;
  final prompt = TextEditingController();

  @override
  void initState() { super.initState(); initialize(); }

  Future<void> initialize() async {
    setState(() { loading = true; error = null; tags = []; disabled = {'rating'}; warnings = []; stage = null; jobId = null; updatePrompt(); });
    try {
      if (repo == null) {
        repo = widget.repository ?? ImagePromptRepository(ImagePromptHostService.baseUrl, await ImagePromptHostService.instance.start());
      }
      final saved = await repo!.load(widget.source, widget.page);
      if (!mounted) return;
      version = saved['version'] as int;
      final document = saved['document'] as PromptJson?;
      if (document != null) apply(document);
      final latest = saved['latestJob'] as PromptJson?;
      if (latest?['state'] == 'running') {
        jobId = latest!['id']; analyzing = true; stage = latest['stage']; startPoll();
      } else if (document == null && latest?['state'] == 'completed') {
        jobId = latest!['id']; apply(latest['result']); dirty = true;
      } else if (document == null && latest?['state'] == 'failed') {
        error = latest!['error'];
      }
    } catch (e) { if (mounted) error = message(e); }
    finally { if (mounted) setState(() => loading = false); }
  }

  String message(Object e) {
    if (e is DioException) {
      if (e.response?.statusCode == 409) return '別の画面で保存されています。変更を控えてから再読込してください。';
      if (e.response?.data is Map && e.response!.data['detail'] is String) return e.response!.data['detail'];
      return '解析ホストに接続できません。画像解析画面を開き直して再試行してください。';
    }
    return '$e';
  }

  void apply(PromptJson document) {
    tags = (document['tags'] as List).map((t) => Map<String, dynamic>.from(t)).toList();
    disabled = Set<String>.from(document['disabledCategories'] as List);
    warnings = List<String>.from(document['warnings'] as List? ?? []);
    jobId = document['jobId'] as String? ?? jobId;
    analysisSeconds = (document['timings']?['totalSeconds'] as num?)?.toDouble();
    execution = document['execution'] as String?;
    updatePrompt();
  }

  void updatePrompt() => prompt.text = selectedPrompt(tags, disabled);
  void edit(VoidCallback change) => setState(() { change(); dirty = true; updatePrompt(); });

  Future<bool> confirm(String title, String text) async => await showDialog<bool>(context: context,
    builder: (context) => AlertDialog(title: Text(title), content: Text(text), actions: [
      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('キャンセル')),
      FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('続ける')),
    ])) ?? false;

  Future<void> analyze() async {
    if (analyzing || repo == null) return;
    if (tags.isNotEmpty && !await confirm('再解析', '画面の候補を新しい解析結果に置き換えます。保存済みの結果は「保存」を押すまで保持されます。')) return;
    if (!mounted) return;
    setState(() { analyzing = true; stage = '画像を準備中'; error = null; });
    try {
      final bytes = await widget.image();
      if (!mounted) return;
      preview = bytes;
      final job = await repo!.analyze(widget.source, widget.page, bytes);
      if (!mounted) return;
      jobId = job['id']; stage = job['stage']; startPoll();
    } catch (e) { if (mounted) setState(() { error = message(e); analyzing = false; }); }
  }

  void startPoll() {
    timer?.cancel();
    timer = Timer.periodic(const Duration(seconds: 2), (_) => poll());
    poll();
  }

  Future<void> poll() async {
    if (_polling || !mounted || jobId == null) return;
    _polling = true;
    try {
      final job = await repo!.job(jobId!);
      if (!mounted) return;
      setState(() {
        stage = job['stage']; error = null;
        if (job['state'] != 'running') {
          timer?.cancel(); analyzing = false;
          if (job['state'] == 'completed') { apply(job['result']); dirty = true; }
          else { error = job['error']; }
        }
      });
    } catch (e) { if (mounted) setState(() => error = message(e)); }
    finally { _polling = false; }
  }

  Future<void> useForGeneration() async {
    final value = prompt.text.trim();
    if (value.isEmpty || openingGeneration || analyzing) return;
    setState(() { openingGeneration = true; error = null; });
    GeneratedMediaRepository? generationRepo;
    try {
      if (widget.openGeneration != null) {
        await widget.openGeneration!(value);
      } else {
        final service = LocalGenerationService.instance;
        final token = await service.start();
        if (!mounted) return;
        generationRepo = GeneratedMediaRepository(LocalGenerationService.baseUrl, token);
        await Navigator.push(context, MaterialPageRoute(builder: (_) => GenerationJobsPage(
          repo: generationRepo!, initialPositivePrompt: value,
          reconnect: () async { await service.start(); },
        )));
      }
    } catch (e) {
      if (mounted) setState(() => error = '画像生成を開けません: $e');
    } finally {
      generationRepo?.close();
      if (mounted) setState(() => openingGeneration = false);
    }
  }

  Future<void> save() async {
    setState(() { saving = true; error = null; });
    try {
      final saved = await repo!.save({'source': widget.source, 'page': widget.page, 'expectedVersion': version,
        'jobId': jobId, 'tags': tags, 'disabledCategories': disabled.toList()});
      if (!mounted) return;
      setState(() { version = saved['version']; dirty = false; });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('画像に紐づけて保存しました')));
    } catch (e) { if (mounted) setState(() => error = message(e)); }
    finally { if (mounted) setState(() => saving = false); }
  }

  Future<void> editTag([PromptJson? tag, String category = 'other']) async {
    final text = TextEditingController(text: tag?['text'] ?? '');
    var selected = tag?['category'] as String? ?? category;
    final accepted = await showDialog<bool>(context: context, builder: (context) => StatefulBuilder(builder: (context, update) => AlertDialog(
      title: Text(tag == null ? '英語タグを追加' : 'タグを編集'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: text, maxLength: 160, decoration: const InputDecoration(labelText: '英語のフレーズ / Danbooruタグ')),
        DropdownButton<String>(isExpanded: true, value: selected, items: [for (final c in promptCategories.entries) DropdownMenuItem(value: c.key, child: Text(c.value))], onChanged: (v) => update(() => selected = v!)),
      ]), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
        FilledButton(onPressed: () { if (text.text.trim().isNotEmpty) Navigator.pop(context, true); }, child: const Text('反映'))],
    )));
    final value = text.text.trim(); text.dispose();
    if (accepted != true || !mounted) return;
    if (tag == null && tags.length >= 300) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('タグは300件まで保存できます。不要なタグを削除してください。')));
      return;
    }
    edit(() {
      if (tag != null) { tag['text'] = value; tag['category'] = selected; tag['sources'] = ['manual']; tag['confidence'] = null; }
      else { tags.add({'text': value, 'category': selected, 'enabled': true, 'sources': ['manual'], 'confidence': null}); }
    });
  }

  @override
  void dispose() { timer?.cancel(); if (widget.repository == null) repo?.close(); prompt.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !dirty,
    onPopInvokedWithResult: (didPop, result) async {
      if (didPop) return;
      if (await confirm('未保存の変更', '保存せずに戻りますか？') && context.mounted) {
        setState(() => dirty = false);
        await WidgetsBinding.instance.endOfFrame;
        if (context.mounted) Navigator.pop(context);
      }
    },
    child: Scaffold(
      appBar: AppBar(title: const Text('Image to Prompt'), actions: [
        IconButton(tooltip: '保存済みを再読込', onPressed: loading || analyzing ? null : () async {
          if (!dirty || await confirm('再読込', '保存していない変更を破棄しますか？')) { if (mounted) { dirty = false; await initialize(); } }
        }, icon: const Icon(Icons.refresh)),
      ]),
      bottomNavigationBar: SafeArea(child: Padding(padding: const EdgeInsets.all(12), child: Wrap(spacing: 12, runSpacing: 8, alignment: WrapAlignment.center, children: [
        FilledButton.icon(onPressed: loading || analyzing || openingGeneration ? null : analyze, icon: const Icon(Icons.image_search), label: const Text('この画像を解析')),
        FilledButton.icon(onPressed: loading || analyzing || openingGeneration || prompt.text.trim().isEmpty ? null : useForGeneration,
          icon: const Icon(Icons.auto_awesome), label: Text(openingGeneration ? '画像生成を準備中…' : 'このプロンプトで画像生成')),
        FilledButton.tonalIcon(onPressed: loading || analyzing || saving || !dirty || jobId == null ? null : save, icon: const Icon(Icons.save_outlined), label: Text(saving ? '保存中…' : '結果を保存')),
        OutlinedButton.icon(onPressed: prompt.text.isEmpty ? null : () async {
          await Clipboard.setData(ClipboardData(text: prompt.text));
          if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('英語プロンプトをコピーしました')));
        }, icon: const Icon(Icons.copy), label: const Text('プロンプトをコピー')),
      ]))),
      body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1000), child: ListView(padding: const EdgeInsets.all(16), children: [
        Text('${widget.title} · ${widget.page}ページ', style: Theme.of(context).textTheme.titleLarge),
        const Text('このPCの解析ホストで手動解析します。QwenをGPUで高速解析し、ComfyUIとは順番にGPUを使用します。推定タグは誤認識を確認して編集してください。Qwenの結果には信頼度を付けず、数値はWD14のスコアを表示します。'),
        if (preview != null) Padding(padding: const EdgeInsets.all(12), child: Image.memory(preview!, height: 180, fit: BoxFit.contain)),
        if (loading || analyzing) const LinearProgressIndicator(),
        if (loading) const Text('解析ホストと保存結果を確認中…'),
        if (stage != null) Text(_stages[stage] ?? stage!),
        if (analyzing) const Text('GPUの空き待ちやモデルの初回読み込みには時間がかかる場合があります。画面を閉じてもホストで解析を続けます。'),
        if (error != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: SelectableText(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
        if (analysisSeconds != null) Text('解析時間: ${analysisSeconds!.toStringAsFixed(1)}秒（Qwen: ${execution == 'gpu' ? 'GPU' : 'CPU'} / WD14: CPU）'),
        if (dirty) const Text('未保存の変更があります'),
        for (final warning in warnings) Text('要確認: $warning'),
        if (tags.isNotEmpty) ...[
          const SizedBox(height: 16),
          TextField(controller: prompt, readOnly: true, maxLines: 5, decoration: const InputDecoration(labelText: '選択タグから生成した英語プロンプト', border: OutlineInputBorder())),
          for (final category in promptCategories.entries)
            Card(child: ExpansionTile(title: Text('${category.value}（${tags.where((t) => t['category'] == category.key).length}）'),
              leading: Switch(value: !disabled.contains(category.key), onChanged: analyzing ? null : (value) => edit(() { value ? disabled.remove(category.key) : disabled.add(category.key); })),
              children: [
                for (final tag in tags.where((t) => t['category'] == category.key))
                  ListTile(leading: Checkbox(value: tag['enabled'] != false, onChanged: analyzing ? null : (v) => edit(() => tag['enabled'] = v)),
                    title: Text(tag['text']), subtitle: Text('${(tag['sources'] as List? ?? []).join(' + ')}${tag['confidence'] == null ? '' : ' · WD14 ${(100 * (tag['confidence'] as num)).toStringAsFixed(1)}%'}'),
                    onTap: analyzing ? null : () => editTag(tag),
                    trailing: IconButton(tooltip: 'タグを削除', onPressed: analyzing ? null : () => edit(() => tags.remove(tag)), icon: const Icon(Icons.close))),
                TextButton.icon(onPressed: analyzing ? null : () => editTag(null, category.key), icon: const Icon(Icons.add), label: const Text('タグを追加')),
              ])),
        ] else if (!loading && !analyzing) const Padding(padding: EdgeInsets.all(24), child: Text('「この画像を解析」を押すと、Qwen3-VLとWD14で特徴を抽出します。')),
      ]))),
    ),
  );
}
