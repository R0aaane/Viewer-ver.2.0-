import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';

import '../repository/generated_media_repository.dart';
import 'generation_comparison_page.dart';

const _states = {
  'queued': '待機中',
  'submitting': '送信中',
  'running': '実行中',
  'importing': '画像を登録中',
  'completed': '完了',
  'failed': '失敗',
  'cancel_requested': 'キャンセル待ち',
  'cancelled': 'キャンセル済み',
};

class GenerationJobsPage extends StatefulWidget {
  final GeneratedMediaRepository repo;
  final Future<void> Function()? reconnect;
  final String? initialPositivePrompt;
  final VoidCallback? viewImages;
  const GenerationJobsPage({super.key, required this.repo, this.reconnect, this.initialPositivePrompt, this.viewImages});

  @override
  State<GenerationJobsPage> createState() => _GenerationJobsPageState();
}

class _GenerationJobsPageState extends State<GenerationJobsPage> {
  bool reconnecting = false;
  String? handoffPrompt;
  bool handoffApplied = false;
  List<GalleryJson> presets = [];
  List<GalleryJson> jobs = [];
  GalleryJson? preset;
  final controllers = <String, TextEditingController>{};
  final form = GlobalKey<FormState>();
  final scroll = ScrollController();
  late SharedPreferences preferences;
  bool randomSeed = true;
  bool restoring = false;
  String? error;
  String? actionError;
  bool busy = false;
  bool refreshing = false;
  bool initialized = false;
  bool historyEnd = false;
  GalleryJson? pending;
  GalleryJson? transferStatus;
  late final Timer timer;
  // Persist uncertain submissions across navigation, app exit and phone sleep.
  late final storageKey =
      'generation.pending.${sha256.convert(utf8.encode('${widget.repo.originalUrl('')}|${widget.repo.headers['Authorization'] ?? ''}'))}';
  late final draftKey = '$storageKey.draft';

  @override
  void initState() {
    super.initState();
    final incoming = widget.initialPositivePrompt?.trim();
    handoffPrompt = incoming == null || incoming.isEmpty ? null : incoming;
    initialize();
    timer = Timer.periodic(const Duration(seconds: 3), (_) => refresh());
  }

  @override
  void dispose() {
    timer.cancel();
    scroll.dispose();
    for (final controller in controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String message(Object exception) {
    if (exception is DioException) {
      final detail = exception.response?.data;
      if (detail is Map && detail['detail'] is String) return detail['detail'];
      if ([401, 403].contains(exception.response?.statusCode)) {
        return '認証トークンを確認してください';
      }
    }
    return '通信または保存に失敗しました。更新して再試行してください';
  }

  Future<void> initialize() async {
    try {
      preferences = await SharedPreferences.getInstance();
      final saved = preferences.getString(storageKey);
      final restored = saved == null ? null : jsonDecode(saved) as GalleryJson;
      final savedDraft = preferences.getString(draftKey);
      final draft = savedDraft == null ? null : jsonDecode(savedDraft) as GalleryJson;
      final available = await widget.repo.presets();
      if (!mounted) return;
      setState(() {
        pending = restored;
        presets = available;
        error = null;
        if (presets.isNotEmpty) {
          choose(
            presets.firstWhere(
              (p) => p['id'] == (restored?['request']['preset'] ?? draft?['preset']) &&
                  (restored != null || handoffPrompt == null ||
                      (p['parameters'] as Map).containsKey('positive')),
              orElse: () => handoffPrompt != null && restored == null
                  ? presets.firstWhere((p) => (p['parameters'] as Map).containsKey('positive'), orElse: () => presets.first)
                  : presets.first,
            ),
          );
          if (preset!['id'] == draft?['preset']) {
            randomSeed = draft?['randomSeed'] != false;
            if (restored == null) applyValues(draft!['parameters']);
          }
          if (restored != null && preset!['id'] == restored['request']['preset']) {
            applyValues(restored['request']['parameters']);
          } else if (handoffApplied) {
            controllers['positive']!.text = handoffPrompt!;
          }
        }
        initialized = true;
      });
      await refresh();
    } catch (exception) {
      if (mounted) setState(() => error = message(exception));
    }
  }

  void choose(GalleryJson selected, {bool applyHandoff = true}) {
    final prompts = {
      for (final name in ['positive', 'negative'])
        if (controllers.containsKey(name)) name: controllers[name]!.text,
    };
    for (final controller in controllers.values) {
      controller.dispose();
    }
    controllers.clear();
    preset = selected;
    final specs = selected['parameters'] as Map;
    for (final name in specs.keys.cast<String>()) {
      controllers[name] = TextEditingController(
        text: prompts[name] ?? '${specs[name]['default']}',
      );
    }
    if (applyHandoff && handoffPrompt != null && pending == null &&
        controllers.containsKey('positive') &&
        (!handoffApplied || !prompts.containsKey('positive'))) {
      controllers['positive']!.text = handoffPrompt!;
      handoffApplied = true;
    }
  }

  void applyValues(Map values) {
    for (final entry in controllers.entries) {
      final spec = preset!['parameters'][entry.key];
      final value = values[entry.key];
      if (value != null &&
          (spec['type'] != 'choice' || (spec['choices'] as List).contains(value))) {
        entry.value.text = '$value';
      }
    }
  }

  Future<void> saveDraft() async {
    if (preset == null || pending != null) return;
    final content = jsonEncode({
      'preset': preset!['id'],
      'randomSeed': randomSeed,
      'parameters': controllers.map((name, controller) => MapEntry(name, controller.text)),
    });
    try {
      if (!await preferences.setString(draftKey, content)) {
        throw StateError('Cannot save draft');
      }
    } catch (_) {
      if (mounted) setState(() => actionError = '下書きを保存できませんでした');
    }
  }

  Future<void> restoreJob(GalleryJson row) async {
    if (busy || pending != null) return;
    setState(() {
      busy = restoring = true;
      actionError = null;
    });
    try {
      final job = await widget.repo.job(row['id']);
      if (!mounted) return;
      final matching = presets.where((item) => item['id'] == job['preset']);
      final parameters = job['parameters'];
      if (matching.isEmpty || parameters is! Map) {
        throw StateError('Unavailable generation settings');
      }
      final selected = matching.first;
      final specs = selected['parameters'] as Map;
      if (specs.keys.any((name) => !parameters.containsKey(name) ||
          (specs[name]['type'] == 'choice' &&
              !(specs[name]['choices'] as List).contains(parameters[name])))) {
        throw StateError('Incompatible generation settings');
      }
      setState(() {
        choose(selected, applyHandoff: false);
        applyValues(parameters);
        randomSeed = false;
        handoffApplied = false;
      });
      await saveDraft();
      if (!mounted) return;
      if (scroll.hasClients) {
        unawaited(scroll.animateTo(0, duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut));
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('生成条件を入力欄に復元しました')),
      );
    } catch (exception) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(exception is StateError
            ? '生成条件を復元できません。プリセットやモデルが変更されたか、ホストの更新が必要です。'
            : message(exception)),
      ));
    } finally {
      if (mounted) setState(() => busy = restoring = false);
    }
  }

  Future<void> refresh({bool older = false}) async {
    if (!initialized || refreshing) return;
    refreshing = true;
    try {
      final loaded = await widget.repo.jobs(
        before: older && jobs.isNotEmpty
            ? (jobs.last['created'] as num).toDouble()
            : null,
      );
      final transfers = await widget.repo.relayStatus();
      var lastPage = loaded;
      while (!older && lastPage.length == 100 && loaded.length < jobs.length) {
        lastPage = await widget.repo.jobs(
          before: (loaded.last['created'] as num).toDouble(),
        );
        loaded.addAll(lastPage);
      }
      if (!mounted) return;
      setState(() {
        if (older) {
          final ids = jobs.map((j) => j['id']).toSet();
          jobs.addAll(loaded.where((j) => !ids.contains(j['id'])));
        } else {
          jobs = loaded;
        }
        transferStatus = transfers;
        historyEnd = lastPage.length < 100;
        error = null;
      });
    } catch (exception) {
      if (mounted) setState(() => error = message(exception));
    } finally {
      refreshing = false;
    }
  }

  Object value(String name, GalleryJson spec) {
    final raw = controllers[name]!.text;
    return switch (spec['type']) {
      'integer' => int.parse(raw),
      'number' => double.parse(raw),
      _ => raw,
    };
  }

  bool get hasSeed => preset?['parameters']['seed']?['type'] == 'integer';

  int newSeed(GalleryJson spec) {
    final min = spec['min'] as int;
    final step = (spec['step'] as num?)?.toInt() ?? 1;
    final count = ((spec['max'] as int) - min) ~/ step + 1;
    return min + (Random.secure().nextDouble() * count).floor() * step;
  }

  String? validate(String name, GalleryJson spec) {
    try {
      final parsed = value(name, spec);
      if (parsed is num) {
        if (!parsed.isFinite || parsed < spec['min'] || parsed > spec['max']) {
          return '${spec['min']}〜${spec['max']}で入力してください';
        }
        final step = spec['step'];
        if (step is num) {
          final count = (parsed - spec['min']) / step;
          if ((count - count.round()).abs() > 0.000001) {
            return '$step刻みで入力してください';
          }
        }
      } else if ('$parsed'.length > (spec['maxLength'] ?? 8192)) {
        return '文字数が上限を超えています';
      }
    } on FormatException {
      return '数値を入力してください';
    }
    return null;
  }

  Future<void> submit() async {
    if (busy || preset == null) return;
    if (pending == null && !form.currentState!.validate()) return;
    setState(() {
      busy = true;
      actionError = null;
    });
    try {
      if (pending == null) {
        final specs = preset!['parameters'] as Map;
        unawaited(saveDraft());
        pending = {
          'key': List.generate(
            16,
            (_) =>
                Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
          ).join(),
          'request': {
            'preset': preset!['id'],
            'parameters': {
              for (final name in controllers.keys)
                name: name == 'seed' && hasSeed && randomSeed
                    ? newSeed(specs[name])
                    : value(name, specs[name]),
            },
          },
        };
      }
      final preferences = await SharedPreferences.getInstance();
      if (!await preferences.setString(storageKey, jsonEncode(pending))) {
        throw StateError('Cannot persist submission');
      }
      await widget.repo.submitJob(pending!['key'], pending!['request']);
      if (!await preferences.remove(storageKey)) {
        throw StateError('Cannot clear submission');
      }
      if (mounted) setState(() => pending = null);
      await refresh();
    } catch (exception) {
      if (mounted) setState(() => actionError = message(exception));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> clearPending() async {
    final clear = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('送信内容をクリア'),
        content: const Text('送信済みのジョブは継続します。履歴を確認してから新しく生成してください。'),
        actions: [
          if (widget.viewImages != null)
            TextButton.icon(onPressed: widget.viewImages, icon: const Icon(Icons.photo_library_outlined), label: const Text('ホストの生成画像')),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('戻る'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('クリア'),
          ),
        ],
      ),
    );
    if (clear != true || !mounted) return;
    try {
      final preferences = await SharedPreferences.getInstance();
      if (!await preferences.remove(storageKey)) {
        throw StateError('Cannot clear submission');
      }
      if (mounted) setState(() => pending = null);
    } catch (exception) {
      if (mounted) setState(() => error = message(exception));
    }
  }

  Future<void> cancel(GalleryJson job) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('生成をキャンセル'),
        content: const Text('実行中の場合は処理の終了を待ちます。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('戻る'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('キャンセルする'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.repo.cancelJob(job['id']);
      await refresh();
    } catch (exception) {
      if (mounted) setState(() => error = message(exception));
    }
  }

  String? transferMessage(GalleryJson job) {
    final ids = (job['mediaIds'] as List).cast<String>();
    if (ids.isEmpty || transferStatus == null) return null;
    if (transferStatus!['configured'] != true) return 'ホストへの自動送信が未設定です';
    final transfers = (transferStatus!['items'] as List).cast<GalleryJson>();
    final matched = transfers.where((t) => ids.contains(t['mediaId'])).toList();
    if (matched.length == ids.length && matched.every((t) => t['state'] == 'sent')) {
      return 'ホストへ送信済み · クライアントの「生成画像」で閲覧できます';
    }
    final errors = matched.where((t) => t['error'] != null);
    return errors.isNotEmpty ? 'ホスト送信待ち: ${errors.first['error']}' : 'ホストへ自動送信中・送信待ち';
  }

  Future<void> reconnect() async {
    if (reconnecting) return;
    setState(() => reconnecting = true);
    try {
      await widget.reconnect!();
      await refresh();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('ComfyUIに接続しました。送信済みジョブは履歴を確認して復旧します。失敗したジョブは生成内容を確認して再度生成してください。')));
    } catch (error) {
      if (mounted) setState(() => actionError = '再接続できません: $error');
    } finally {
      if (mounted) setState(() => reconnecting = false);
    }
  }

  void compare({GalleryJson? job}) {
    final candidates = job == null ? jobs : [job];
    final images = <String, String>{};
    for (final candidate in candidates) {
      final ids = (candidate['mediaIds'] as List).cast<String>();
      final created = DateTime.fromMillisecondsSinceEpoch(
        ((candidate['created'] as num) * 1000).round(),
      ).toLocal();
      final date = MaterialLocalizations.of(context).formatShortDate(created);
      final time = MaterialLocalizations.of(context).formatTimeOfDay(
        TimeOfDay.fromDateTime(created),
        alwaysUse24HourFormat: true,
      );
      for (final (index, id) in ids.indexed) {
        images.putIfAbsent(id, () => '$date $time · ${index + 1}枚目');
      }
    }
    Navigator.push<void>(context, MaterialPageRoute(
      builder: (_) => GenerationComparisonPage(
        repo: widget.repo,
        images: images,
        viewImages: widget.viewImages,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final specs = preset?['parameters'] as Map? ?? {};
    return Scaffold(
      appBar: AppBar(
        title: const Text('画像生成'),
        actions: [
          IconButton(
            tooltip: '生成結果を比較',
            icon: const Icon(Icons.compare_outlined),
            onPressed: jobs.any((job) => (job['mediaIds'] as List).isNotEmpty)
                ? () => compare()
                : null,
          ),
          IconButton(
            tooltip: '更新',
            icon: const Icon(Icons.refresh),
            onPressed: () => initialized ? refresh() : initialize(),
          ),
        ],
      ),
      bottomNavigationBar: presets.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(double.infinity, 52),
                  ),
                  icon: const Icon(Icons.auto_awesome),
                  onPressed: busy ? null : submit,
                  label: Text(
                    restoring
                        ? '生成条件を読み込み中…'
                        : busy
                        ? '送信中…'
                        : pending == null
                        ? '生成する'
                        : '前回の送信を確認・再試行',
                  ),
                ),
              ),
            ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '描きたいイメージを画像に',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'プリセットを選び、描きたい内容を入力して「生成する」を押してください。進み具合と完成した画像は下の生成履歴で確認できます。',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (widget.reconnect != null)
                Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: OutlinedButton.icon(
                  onPressed: reconnecting ? null : reconnect,
                  icon: const Icon(Icons.sync),
                  label: Text(reconnecting ? 'ComfyUIの起動・接続を確認中…' : 'ComfyUIを起動・再接続'),
                )),
              if (handoffPrompt != null)
                Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(handoffApplied
                        ? '解析プロンプトを入力しました。モデル・LoRAなどを確認して「生成する」を押してください。'
                        : pending != null
                            ? '前回の送信内容を保持しています。送信結果の確認またはクリア後に、解析プロンプトを適用できます。'
                            : controllers.containsKey('positive')
                                ? '解析プロンプトを適用して、新しい画像を生成できます。'
                                : 'このプリセットには入力先がありません。プロンプトを入力できるプリセットを選んでください。'),
                    if (!handoffApplied)
                      TextButton(onPressed: pending != null || busy || !controllers.containsKey('positive') ? null : () => setState(() {
                        controllers['positive']!.text = handoffPrompt!;
                        handoffApplied = true;
                        unawaited(saveDraft());
                      }), child: const Text('解析プロンプトを適用')),
                  ],
                ))),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(error!),
                ),
              if (actionError != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(actionError!),
                ),
              if (!initialized && error == null)
                const LinearProgressIndicator(),
              if (initialized && presets.isEmpty)
                const Text('ホスト側でワークフロープリセットを登録してください'),
              if (presets.isNotEmpty)
                Form(
                  key: form,
                  child: Column(
                    children: [
                      DropdownButtonFormField<String>(
                        key: ValueKey(preset!['id']),
                        isExpanded: true,
                        initialValue: preset?['id'],
                        decoration: const InputDecoration(
                          labelText: 'ワークフロープリセット',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          for (final item in presets)
                            DropdownMenuItem(
                              value: item['id'],
                              child: Text(item['name']),
                            ),
                        ],
                        onChanged: busy || pending != null
                            ? null
                            : (id) {
                                setState(() => choose(
                                  presets.firstWhere((p) => p['id'] == id),
                                ));
                                unawaited(saveDraft());
                              },
                      ),
                      if (specs.containsKey('lora_name'))
                        const Padding(padding: EdgeInsets.only(top: 12), child: Text(
                          'LoRAはチェックポイントと同じ系列（Illustrious / SDXLなど）を選んでください。必要なトリガーワードは描きたい内容に入力します。LoRAを使わない場合は通常プリセットを選択してください。')),
                      if (hasSeed)
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Seedを毎回ランダムにする'),
                          subtitle: Text(pending == null
                              ? 'オフにすると値を固定できます'
                              : '前回送信したSeed: ${pending!['request']['parameters']['seed'] ?? '不明'}'),
                          value: randomSeed,
                          onChanged: busy || pending != null ? null : (enabled) {
                            setState(() => randomSeed = enabled);
                            unawaited(saveDraft());
                          },
                        ),
                      for (final name in controllers.keys)
                        if (!(name == 'seed' && hasSeed && randomSeed))
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: specs[name]['type'] == 'choice'
                              ? DropdownButtonFormField<String>(
                                  isExpanded: true,
                                  key: ValueKey('${preset!['id']}.$name'),
                                  initialValue: controllers[name]!.text,
                                  decoration: InputDecoration(
                                    labelText: specs[name]['label'] ?? name,
                                    border: const OutlineInputBorder(),
                                  ),
                                  items: [
                                    for (final item in specs[name]['choices'])
                                      DropdownMenuItem(
                                        value: item as String,
                                        child: Text(item),
                                      ),
                                  ],
                                  onChanged: busy || pending != null
                                      ? null
                                      : (choice) {
                                          controllers[name]!.text = choice!;
                                          unawaited(saveDraft());
                                        },
                                )
                              : TextFormField(
                                  controller: controllers[name],
                                  onChanged: (_) => unawaited(saveDraft()),
                                  enabled: !busy && pending == null,
                                  decoration: InputDecoration(
                                    labelText: specs[name]['label'] ?? name,
                                    border: const OutlineInputBorder(),
                                    alignLabelWithHint: true,
                                    helperText: name == 'positive'
                                        ? '例: a small cat in a sunny garden, watercolor'
                                        : name == 'negative'
                                        ? '画像に含めたくない要素（省略可）'
                                        : null,
                                  ),
                                  maxLines: specs[name]['type'] == 'text'
                                      ? 3
                                      : 1,
                                  keyboardType: specs[name]['type'] == 'text'
                                      ? TextInputType.multiline
                                      : const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                  validator: (_) => validate(name, specs[name]),
                                ),
                        ),
                      const SizedBox(height: 16),
                      if (pending != null)
                        TextButton(
                          onPressed: busy ? null : clearPending,
                          child: const Text('送信内容をクリア'),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 24),
              Text('生成履歴', style: Theme.of(context).textTheme.titleMedium),
              if (initialized && jobs.isEmpty) const Text('生成ジョブはありません'),
              for (final job in jobs)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: (job['mediaIds'] as List).isEmpty
                      ? Icon(
                          job['state'] == 'failed'
                              ? Icons.error_outline
                              : Icons.hourglass_top,
                        )
                      : SizedBox(
                          width: 64,
                          height: 64,
                          child: GenerationThumbnail(repo: widget.repo, id: job['mediaIds'][0]),
                        ),
                  onTap: (job['mediaIds'] as List).isEmpty
                      ? null
                      : () => compare(job: job),
                  title: Text(
                    '${_states[job['state']] ?? job['state']} · ${job['preset']}',
                  ),
                  subtitle: Text(
                    [
                      DateTime.fromMillisecondsSinceEpoch(
                        ((job['created'] as num) * 1000).round(),
                      ).toLocal().toString().split('.').first,
                      if (job['progress'] is Map)
                        '${job['progress']['value']} / ${job['progress']['max']}',
                      if (job['error'] != null) job['error'],
                      if (transferMessage(job) != null) transferMessage(job)!,
                      if ((job['mediaIds'] as List).isNotEmpty)
                        '${(job['mediaIds'] as List).length}枚 · タップして生成結果を表示',
                    ].join('\n'),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '生成条件を復元',
                        icon: const Icon(Icons.restore),
                        onPressed: busy || pending != null || presets.isEmpty
                            ? null : () => restoreJob(job),
                      ),
                      if (['queued', 'submitting', 'running'].contains(job['state']))
                        IconButton(
                          tooltip: '生成をキャンセル',
                          icon: const Icon(Icons.cancel_outlined),
                          onPressed: () => cancel(job),
                        ),
                    ],
                  ),
                ),
              if (!historyEnd && jobs.isNotEmpty)
                TextButton(
                  onPressed: () => refresh(older: true),
                  child: const Text('以前の履歴を読み込む'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
