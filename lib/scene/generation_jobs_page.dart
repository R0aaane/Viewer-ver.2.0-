import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';

import '../repository/generated_media_repository.dart';

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
  const GenerationJobsPage({super.key, required this.repo});

  @override
  State<GenerationJobsPage> createState() => _GenerationJobsPageState();
}

class _GenerationJobsPageState extends State<GenerationJobsPage> {
  List<GalleryJson> presets = [];
  List<GalleryJson> jobs = [];
  GalleryJson? preset;
  final controllers = <String, TextEditingController>{};
  final form = GlobalKey<FormState>();
  String? error;
  String? actionError;
  bool busy = false;
  bool refreshing = false;
  bool initialized = false;
  bool historyEnd = false;
  GalleryJson? pending;
  late final Timer timer;
  // Persist uncertain submissions across navigation, app exit and phone sleep.
  late final storageKey =
      'generation.pending.${sha256.convert(utf8.encode('${widget.repo.originalUrl('')}|${widget.repo.headers['Authorization'] ?? ''}'))}';

  @override
  void initState() {
    super.initState();
    initialize();
    timer = Timer.periodic(const Duration(seconds: 3), (_) => refresh());
  }

  @override
  void dispose() {
    timer.cancel();
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
      final preferences = await SharedPreferences.getInstance();
      final saved = preferences.getString(storageKey);
      final restored = saved == null ? null : jsonDecode(saved) as GalleryJson;
      final available = await widget.repo.presets();
      if (!mounted) return;
      setState(() {
        pending = restored;
        presets = available;
        initialized = true;
        error = null;
        if (presets.isNotEmpty) {
          choose(
            presets.firstWhere(
              (p) => p['id'] == restored?['request']['preset'],
              orElse: () => presets.first,
            ),
          );
          if (restored != null &&
              preset!['id'] == restored['request']['preset']) {
            final values = restored['request']['parameters'] as Map;
            for (final name in controllers.keys) {
              final spec = preset!['parameters'][name];
              if (values.containsKey(name) &&
                  (spec['type'] != 'choice' ||
                      (spec['choices'] as List).contains(values[name]))) {
                controllers[name]!.text = '${values[name]}';
              }
            }
          }
        }
      });
      await refresh();
    } catch (exception) {
      if (mounted) setState(() => error = message(exception));
    }
  }

  void choose(GalleryJson selected) {
    for (final controller in controllers.values) {
      controller.dispose();
    }
    controllers.clear();
    preset = selected;
    final specs = selected['parameters'] as Map;
    for (final name in specs.keys.cast<String>()) {
      controllers[name] = TextEditingController(
        text: '${specs[name]['default']}',
      );
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
                name: value(name, specs[name]),
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

  @override
  Widget build(BuildContext context) {
    final specs = preset?['parameters'] as Map? ?? {};
    return Scaffold(
      appBar: AppBar(
        title: const Text('画像生成'),
        actions: [
          IconButton(
            tooltip: '更新',
            icon: const Icon(Icons.refresh),
            onPressed: () => initialized ? refresh() : initialize(),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
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
          if (!initialized && error == null) const LinearProgressIndicator(),
          if (initialized && presets.isEmpty)
            const Text('ホスト側でワークフロープリセットを登録してください'),
          if (presets.isNotEmpty)
            Form(
              key: form,
              child: Column(
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: preset?['id'],
                    decoration: const InputDecoration(labelText: 'ワークフロープリセット'),
                    items: [
                      for (final item in presets)
                        DropdownMenuItem(
                          value: item['id'],
                          child: Text(item['name']),
                        ),
                    ],
                    onChanged: busy || pending != null
                        ? null
                        : (id) => setState(
                            () => choose(
                              presets.firstWhere((p) => p['id'] == id),
                            ),
                          ),
                  ),
                  for (final name in controllers.keys)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: specs[name]['type'] == 'choice'
                          ? DropdownButtonFormField<String>(
                              key: ValueKey('${preset!['id']}.$name'),
                              initialValue: controllers[name]!.text,
                              decoration: InputDecoration(
                                labelText: specs[name]['label'] ?? name,
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
                                  : (choice) =>
                                        controllers[name]!.text = choice!,
                            )
                          : TextFormField(
                              controller: controllers[name],
                              enabled: !busy && pending == null,
                              decoration: InputDecoration(
                                labelText: specs[name]['label'] ?? name,
                              ),
                              maxLines: specs[name]['type'] == 'text' ? 3 : 1,
                              keyboardType: specs[name]['type'] == 'text'
                                  ? TextInputType.multiline
                                  : const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                              validator: (_) => validate(name, specs[name]),
                            ),
                    ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: busy ? null : submit,
                    child: Text(
                      busy
                          ? '送信中…'
                          : pending == null
                          ? '生成する'
                          : '前回の送信を確認・再試行',
                    ),
                  ),
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
                  if ((job['mediaIds'] as List).isNotEmpty)
                    '${(job['mediaIds'] as List).length}枚をギャラリーに登録',
                ].join('\n'),
              ),
              trailing:
                  ['queued', 'submitting', 'running'].contains(job['state'])
                  ? IconButton(
                      tooltip: '生成をキャンセル',
                      icon: const Icon(Icons.cancel_outlined),
                      onPressed: () => cancel(job),
                    )
                  : null,
            ),
          if (!historyEnd && jobs.isNotEmpty)
            TextButton(
              onPressed: () => refresh(older: true),
              child: const Text('以前の履歴を読み込む'),
            ),
        ],
      ),
    );
  }
}
