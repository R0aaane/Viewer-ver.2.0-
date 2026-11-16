import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'dart:typed_data';
import 'dart:async';

import '../repository/generated_media_repository.dart';
import 'widgets/scene_ui.dart';
import 'generation_jobs_page.dart';

typedef _Json = Map<String, dynamic>;
const _categories = {'artist': 'アーティスト', 'generation': '生成タグ', 'free': '手動タグ', 'character': 'キャラクター', 'series': 'シリーズ'};
const _modes = {'all_tags': 'AND', 'any_tags': 'OR', 'no_tags': 'NOT'};
const _pageSize = 48;

class GeneratedGalleryPage extends StatefulWidget {
  final String baseUrl;
  final String? token;
  final Future<void> Function(List<String>)? sendToHost;
  final Future<void> Function()? reconnect;

  const GeneratedGalleryPage({super.key, required this.baseUrl, this.token, this.sendToHost, this.reconnect});

  @override
  State<GeneratedGalleryPage> createState() => _GeneratedGalleryPageState();
}

class _GeneratedGalleryPageState extends State<GeneratedGalleryPage> {
  late final repo = GeneratedMediaRepository(widget.baseUrl, widget.token);
  final prompt = TextEditingController();
  final selected = <String, int>{};
  String? _selectedEpoch;
  final filters = <({String mode, String category, String name})>[];
  DateTimeRange? dates;
  String sort = 'newest';
  String search = '';
  bool favorites = false;
  bool deleted = false;
  bool _pendingSyncRefresh = false;
  bool _polling = false;
  bool _sendingToHost = false;
  int offset = 0;
  late Future<_Json> page = fetch();
  late Future<List<_Json>> tagIndex = repo.tags();
  late final Timer _connectionTimer;

  @override
  void initState() {
    super.initState();
    _connectionTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => pollChanges(),
    );
    pollChanges();
  }

  Future<void> pollChanges() async {
    if (_polling) return;
    _polling = true;
    try {
      _pendingSyncRefresh = await repo.synchronize() || _pendingSyncRefresh;
      if (mounted && _pendingSyncRefresh && selected.isEmpty) {
        _pendingSyncRefresh = false;
        reload(start: offset);
      }
      await repo.checkConnection();
    } catch (_) {
      // Retain the loaded page while offline and retry on the next poll.
    } finally {
      _polling = false;
    }
  }

  Future<_Json> fetch() async {
    final end = dates?.end;
    return repo.search({
      'deleted': deleted,
      'prompt': search,
      'sort': sort,
      'favorite': favorites,
      'offset': offset,
      'limit': _pageSize,
      if (dates != null) 'from_ms': dates!.start.millisecondsSinceEpoch,
      if (end != null)
        'before_ms': DateTime(
          end.year,
          end.month,
          end.day + 1,
        ).millisecondsSinceEpoch,
      for (final mode in _modes.keys)
        mode: [
          for (final f in filters.where((t) => t.mode == mode))
            {'category': f.category, 'name': f.name},
        ],
    });
  }

  void reload({int start = 0}) {
    setState(() {
      selected.clear();
      offset = start;
      page = fetch();
      tagIndex = repo.tags();
    });
  }

  @override
  void dispose() {
    _connectionTimer.cancel();
    prompt.dispose();
    repo.close();
    super.dispose();
  }

  void toggle(String id, int version, {String? epoch}) => setState(() {
    if (selected.isEmpty) _selectedEpoch = epoch;
    if (selected.remove(id) == null) selected[id] = version;
  });

  Future<void> change(Future<void> Function() operation) async {
    try {
      await operation();
      if (mounted) reload(start: offset);
    } on DioException catch (error) {
      if (mounted) {
        if (error.response?.statusCode == 409) reload(start: offset);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_error(error))));
      }
    }
  }

  Future<void> deleteSelected() async {
    final ids = selected.keys.toList();
    final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('選択した画像を完全削除'),
      content: Text('${ids.length}枚の原本・サムネイル・タグを完全に削除します。このサービスが管理するComfyUI出力元も削除します。復元できません。ホストへ送ったコピーは別途削除してください。'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('キャンセル')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('完全削除')),
      ],
    ));
    if (confirmed != true || !mounted) return;
    await change(() async {
      for (final id in ids) {
        final detail = await repo.detail(id);
        await repo.purgeImage(id, detail['version'] as int, epoch: detail['epoch'] as String?);
      }
    });
  }

  Future<void> chooseTag({required bool filtering}) async {
    final versions = Map.of(selected);
    final epoch = _selectedEpoch;
    final entry =
        await showDialog<({String mode, String category, String name})>(
          context: context,
          builder: (_) =>
              _TagDialog(filtering: filtering, count: versions.length),
        );
    if (!mounted || entry == null) return;
    if (filtering) {
      if (!filters.contains(entry)) filters.add(entry);
      reload();
    } else {
      await change(
        () => repo.editTags(
          versions,
          entry.mode,
          entry.category,
          entry.name,
          epoch: epoch,
        ),
      );
    }
  }

  Future<void> open(_Json row) async {
    final id = row['mediaId'] as String;
    if (selected.isNotEmpty) {
      if (row['tagVersion'] is int) {
        toggle(id, row['tagVersion'], epoch: row['epoch']);
      }
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _GeneratedDetail(repo: repo, id: id),
      ),
    );
    if (mounted) reload(start: offset);
  }

  Future<void> pickDates() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(1970),
      lastDate: DateTime(2100),
      initialDateRange: dates,
    );
    if (range != null && mounted) {
      dates = range;
      reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = selected.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Text(active ? '${selected.length}件を選択' : '生成画像'),
        actions: [
          if (active && widget.sendToHost != null)
            TextButton.icon(
              icon: const Icon(Icons.cloud_upload_outlined),
              label: Text(_sendingToHost ? '送信中…' : 'ホストへ送る'),
              onPressed: _sendingToHost ? null : () async {
                final ids = selected.keys.toList();
                setState(() => _sendingToHost = true);
                try {
                  await widget.sendToHost!(ids);
                  if (mounted) setState(selected.clear);
                } catch (_) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('ホストへ送信できませんでした。ローカル画像は保持されています。接続を確認して再試行してください。')),
                    );
                  }
                } finally {
                  if (mounted) setState(() => _sendingToHost = false);
                }
              },
            ),
          _ConnectionLabel(repo),
          IconButton(
            tooltip: deleted ? 'ギャラリーに戻る' : '削除済み画像',
            icon: Icon(
              deleted ? Icons.photo_library_outlined : Icons.delete_outline,
            ),
            onPressed: () => setState(() {
              deleted = !deleted;
              reload();
            }),
          ),
          IconButton(
            tooltip: '画像を生成',
            icon: const Icon(Icons.auto_awesome),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => GenerationJobsPage(repo: repo, reconnect: widget.reconnect),
                ),
              );
              if (mounted) reload(start: offset);
            },
          ),
          if (active) ...[
            TextButton.icon(
              onPressed: _sendingToHost ? null : deleteSelected,
              icon: const Icon(Icons.delete_forever),
              label: const Text('完全削除'),
            ),
            TextButton.icon(
              label: const Text('タグ編集'),
              icon: const Icon(Icons.sell_outlined),
              onPressed: () => chooseTag(filtering: false),
            ),
            IconButton(
              tooltip: '選択を解除',
              icon: const Icon(Icons.close),
              onPressed: () => setState(selected.clear),
            ),
          ] else
            IconButton(
              tooltip: '更新',
              icon: const Icon(Icons.refresh),
              onPressed: () => reload(start: offset),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (widget.sendToHost != null)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('このPCで生成した画像です。「画像を生成」から作成し、画像のチェックを選んで「ホストへ送る」で転送できます。'),
              ),
            Padding(
              padding: const EdgeInsets.all(SceneSpace.x2),
              child: SceneSearchField(
                controller: prompt,
                hintText: 'プロンプトを検索',
                onSubmitted: (value) {
                  search = value;
                  reload();
                },
                onClear: () {
                  prompt.clear();
                  search = '';
                  reload();
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilterChip(
                    label: const Text('お気に入り'),
                    selected: favorites,
                    onSelected: (v) {
                      favorites = v;
                      reload();
                    },
                  ),
                  ActionChip(
                    label: const Text('タグ条件'),
                    onPressed: () => chooseTag(filtering: true),
                  ),
                  if (dates == null)
                    ActionChip(label: const Text('作成期間'), onPressed: pickDates)
                  else
                    InputChip(
                      label: Text(
                        '${_day(dates!.start)} ～ ${_day(dates!.end)}',
                      ),
                      onPressed: pickDates,
                      onDeleted: () {
                        dates = null;
                        reload();
                      },
                    ),
                  DropdownButton<String>(
                    value: sort,
                    items: const [
                      DropdownMenuItem(value: 'newest', child: Text('新しい順')),
                      DropdownMenuItem(value: 'oldest', child: Text('古い順')),
                      DropdownMenuItem(value: 'name', child: Text('名前順')),
                    ],
                    onChanged: (v) {
                      if (v != null) {
                        sort = v;
                        reload();
                      }
                    },
                  ),
                ],
              ),
            ),
            ExpansionTile(
              title: const Text('アーティスト・生成タグから探す'),
              children: [FutureBuilder<List<_Json>>(
                future: tagIndex,
                builder: (context, snapshot) => Padding(
                  padding: const EdgeInsets.all(8),
                  child: Wrap(spacing: 8, children: [
                    if (!snapshot.hasData) const Text('タグを取得中'),
                    if (snapshot.data?.isEmpty == true) const Text('画像を選択して「タグ編集」で分類できます'),
                    for (final tag in snapshot.data ?? <_Json>[])
                      ActionChip(label: Text('${_categories[tag['category']] ?? tag['category']}: ${tag['name']} (${tag['count']})'),
                        onPressed: () {
                          final entry = (mode: 'all_tags', category: tag['category'] as String, name: tag['name'] as String);
                          if (!filters.contains(entry)) filters.add(entry);
                          reload();
                        }),
                  ]),
                ),
              )],
            ),
            if (filters.isNotEmpty)
              SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final f in filters)
                      InputChip(
                        label: Text(
                          '${_modes[f.mode]} · ${_categories[f.category]} · ${f.name}',
                        ),
                        onDeleted: () {
                          filters.remove(f);
                          reload();
                        },
                      ),
                  ],
                ),
              ),
            Expanded(
              child: FutureBuilder<_Json>(
                future: page,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return SceneEmptyState(
                      icon: Icons.cloud_off,
                      title: _error(snapshot.error),
                    );
                  }
                  final items = (snapshot.data!['items'] as List).cast<_Json>();
                  return Column(
                    children: [
                      Expanded(
                        child: items.isEmpty
                            ? const SceneEmptyState(
                                icon: Icons.collections_outlined,
                                title: '該当する生成画像はありません',
                              )
                            : GridView.builder(
                                padding: const EdgeInsets.all(8),
                                gridDelegate:
                                    const SliverGridDelegateWithMaxCrossAxisExtent(
                                      maxCrossAxisExtent: 200,
                                      crossAxisSpacing: 8,
                                      mainAxisSpacing: 8,
                                    ),
                                itemCount: items.length,
                                itemBuilder: (context, i) {
                                  final row = items[i];
                                  final id = row['mediaId'] as String;
                                  final version = row['tagVersion'] as int?;
                                  final favorite = row['favorite'] == 1;
                                  return Card(
                                    clipBehavior: Clip.antiAlias,
                                    child: InkWell(
                                      onTap: () => open(row),
                                      onLongPress: version != null
                                          ? () => toggle(
                                              id,
                                              version,
                                              epoch: row['epoch'],
                                            )
                                          : null,
                                      child: GridTile(
                                        header: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            Checkbox(
                                              value: selected.containsKey(id),
                                              onChanged: version != null
                                                  ? (_) => toggle(
                                                      id,
                                                      version,
                                                      epoch: row['epoch'],
                                                    )
                                                  : null,
                                            ),
                                            GalleryFavoriteButton(
                                              isFavorite: favorite,
                                              onPressed: () => change(() async {
                                                await repo.favorite(
                                                  id,
                                                  !favorite,
                                                  epoch:
                                                      row['epoch'] as String?,
                                                  version:
                                                      row['version'] as int?,
                                                );
                                              }),
                                            ),
                                          ],
                                        ),
                                        footer: GridTileBar(
                                          title: Text(row['name'] as String),
                                          subtitle: Text((row['tags'] as List? ?? []).map((t) => '${_categories[t['category']] ?? t['category']}: ${t['name']}').join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis),
                                          backgroundColor: Colors.black54,
                                        ),
                                        child: _Thumbnail(
                                          repo,
                                          id,
                                          BoxFit.cover,
                                          key: ValueKey(
                                            '$id.${repo.cacheGeneration}',
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            tooltip: '前のページ',
                            onPressed: offset == 0
                                ? null
                                : () => reload(start: offset - _pageSize),
                            icon: const Icon(Icons.chevron_left),
                          ),
                          Text('${offset ~/ _pageSize + 1}'),
                          IconButton(
                            tooltip: '次のページ',
                            onPressed: snapshot.data!['hasMore'] == true
                                ? () => reload(start: offset + _pageSize)
                                : null,
                            icon: const Icon(Icons.chevron_right),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _day(DateTime t) => t.toIso8601String().split('T').first;

class _ConnectionLabel extends StatelessWidget {
  final GeneratedMediaRepository repo;
  const _ConnectionLabel(this.repo);

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: repo.connection,
    builder: (_, state, _) => Text(switch (state) {
      GalleryConnection.unknown => '接続確認中',
      GalleryConnection.connected => '接続済み',
      GalleryConnection.offline => 'オフライン',
      GalleryConnection.unauthorized => '認証が必要',
      GalleryConnection.unavailable => 'ライブラリ停止中',
    }),
  );
}

class _Thumbnail extends StatefulWidget {
  final GeneratedMediaRepository repo;
  final String id;
  final BoxFit fit;
  const _Thumbnail(this.repo, this.id, this.fit, {super.key});
  @override
  State<_Thumbnail> createState() => _ThumbnailState();
}

class _ThumbnailState extends State<_Thumbnail> {
  late Future<Uint8List> bytes = widget.repo.thumbnail(widget.id);
  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: bytes,
    builder: (_, snapshot) {
      if (snapshot.hasError)
        return IconButton(
          tooltip: 'サムネイルを再取得',
          icon: const Icon(Icons.refresh),
          onPressed: () => setState(() {
            bytes = widget.repo.thumbnail(widget.id);
          }),
        );
      if (!snapshot.hasData) return const SizedBox.shrink();
      return Image.memory(
        snapshot.data!,
        fit: widget.fit,
        errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
      );
    },
  );
}

String _error(Object? error) =>
    switch (error is DioException ? error.response?.statusCode : null) {
      401 || 403 => '認証トークンを確認してください',
      503 || 404 => '生成ライブラリの設定を確認してください',
      422 => '入力した検索条件またはタグを確認してください',
      409 => '別の端末でタグが更新されました。最新のタグを確認して編集し直してください',
      _ => '生成ライブラリに接続できません。更新して再試行してください',
    };

class _TagDialog extends StatefulWidget {
  final bool filtering;
  final int count;
  const _TagDialog({required this.filtering, required this.count});
  @override
  State<_TagDialog> createState() => _TagDialogState();
}

class _TagDialogState extends State<_TagDialog> {
  late String mode = widget.filtering ? 'all_tags' : 'add';
  String category = 'free', name = '';
  @override
  Widget build(BuildContext context) {
    final modes = widget.filtering
        ? _modes
        : const {'add': '付与', 'remove': '解除'};
    return AlertDialog(
      title: Text(widget.filtering ? 'タグ条件' : '${widget.count}件のタグ編集'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButton<String>(
              isExpanded: true,
              value: mode,
              items: [
                for (final e in modes.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) => setState(() => mode = v!),
            ),
            DropdownButton<String>(
              isExpanded: true,
              value: category,
              items: [
                for (final e in _categories.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) => setState(() => category = v!),
            ),
            TextField(
              maxLength: 128,
              decoration: const InputDecoration(labelText: 'タグ名'),
              onChanged: (v) => setState(() => name = v.trim()),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: name.isEmpty
              ? null
              : () => Navigator.pop(context, (
                  mode: mode,
                  category: category,
                  name: name,
                )),
          child: Text(widget.filtering ? '適用' : modes[mode]!),
        ),
      ],
    );
  }
}

class _GeneratedDetail extends StatefulWidget {
  final GeneratedMediaRepository repo;
  final String id;
  const _GeneratedDetail({required this.repo, required this.id});
  @override
  State<_GeneratedDetail> createState() => _GeneratedDetailState();
}

class _GeneratedDetailState extends State<_GeneratedDetail> {
  Future<void> modify(_Json detail, String action) async {
    String? name;
    if (action == 'rename') {
      var editedName = detail['name'] as String;
      name = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('表示名を変更'),
          content: TextFormField(
            initialValue: editedName,
            maxLength: 255,
            onChanged: (value) => editedName = value,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('戻る'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, editedName.trim()),
              child: const Text('保存'),
            ),
          ],
        ),
      );
      if (name == null || name.isEmpty) return;
    } else {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(action == 'purge' ? '画像を完全削除（復元不可）' : action == 'delete' ? '画像を削除済みに移動' : '画像を復元'),
          content: Text('${detail['name']}'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('戻る'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('実行'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    if (!mounted) return;
    try {
      if (action == 'purge') {
        await widget.repo.purgeImage(widget.id, detail['version'], epoch: detail['epoch'] as String?);
        if (mounted) Navigator.pop(context);
        return;
      }
      await widget.repo.editImage(
        widget.id,
        detail['version'],
        name: name,
        deleted: action == 'rename' ? null : action == 'delete',
        epoch: detail['epoch'] as String?,
      );
      if (mounted) refresh();
    } on DioException catch (error) {
      if (mounted) {
        if (error.response?.statusCode == 409) refresh();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_error(error))));
      }
    }
  }

  late Future<_Json> data = widget.repo.detail(widget.id);

  void refresh({bool reanalyze = false}) {
    final request = reanalyze
        ? widget.repo.reanalyze(widget.id)
        : widget.repo.detail(widget.id);
    setState(() {
      data = request;
    });
  }

  Future<void> edit(int version, {String? epoch}) async {
    final entry =
        await showDialog<({String mode, String category, String name})>(
          context: context,
          builder: (_) => const _TagDialog(filtering: false, count: 1),
        );
    if (entry == null || !mounted) return;
    try {
      await widget.repo.editTags(
        {widget.id: version},
        entry.mode,
        entry.category,
        entry.name,
        epoch: epoch,
      );
      if (mounted) {
        refresh();
      }
    } on DioException catch (e) {
      if (mounted) {
        if (e.response?.statusCode == 409) refresh();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_error(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('生成画像の詳細'),
      actions: [
        _ConnectionLabel(widget.repo),
        FutureBuilder<_Json>(
          future: data,
          builder: (context, snapshot) {
            final detail = snapshot.data;
            if (snapshot.connectionState != ConnectionState.done ||
                detail?['version'] is! int) {
              return const SizedBox.shrink();
            }
            return PopupMenuButton<String>(
              tooltip: '画像の操作',
              onSelected: (action) => modify(detail!, action),
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'rename', child: Text('表示名を変更')),
                const PopupMenuItem(value: 'purge', child: Text('完全削除（復元不可）')),
                if (detail!['deleted'] == true)
                  const PopupMenuItem(value: 'restore', child: Text('復元'))
                else
                  const PopupMenuItem(value: 'delete', child: Text('削除済みに移動')),
              ],
            );
          },
        ),
        FutureBuilder<_Json>(
          future: data,
          builder: (context, snapshot) {
            final version = snapshot.connectionState == ConnectionState.done
                ? (snapshot.data?['tagVersion'] as int?)
                : null;
            return IconButton(
              tooltip: 'タグ編集',
              onPressed: version == null
                  ? null
                  : () => edit(version, epoch: snapshot.data?['epoch']),
              icon: const Icon(Icons.sell_outlined),
            );
          },
        ),
      ],
    ),
    body: FutureBuilder<_Json>(
      future: data,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: TextButton(
              onPressed: refresh,
              child: Text(_error(snapshot.error)),
            ),
          );
        }
        final detail = snapshot.data!, gen = detail['generation'] as _Json;
        final url = widget.repo.originalUrl(widget.id);
        final dateLabel = switch (detail['dateSource']) {
          'sourceCreated' => '元画像の作成日時',
          'sourceModified' => '元画像の更新日時',
          _ => '保存画像の更新日時',
        };
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(detail['name'], style: Theme.of(context).textTheme.titleLarge),
            Text(
              '${(gen['dimensions'] as List).join(' × ')} · $dateLabel ${DateTime.fromMillisecondsSinceEpoch(detail['fileTimeMs']).toLocal()}',
            ),
            SizedBox(
              height: 240,
              child: _Thumbnail(widget.repo, widget.id, BoxFit.contain),
            ),
            TextButton.icon(
              icon: const Icon(Icons.zoom_in),
              label: const Text('原寸画像を開く'),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    appBar: AppBar(title: Text(detail['name'])),
                    body: InteractiveViewer(
                      constrained: false,
                      minScale: 0.05,
                      maxScale: 8,
                      child: Image.network(
                        url,
                        headers: widget.repo.headers,
                        errorBuilder: (_, _, _) =>
                            const Icon(Icons.broken_image),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Wrap(
              spacing: 6,
              children: [
                for (final t in detail['tags'])
                  Chip(
                    label: Text('${_categories[t['category']]} · ${t['name']}'),
                  ),
              ],
            ),
            for (final s in gen['samplers'])
              SceneSurfaceCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final field in const {
                      'positive': 'Positive Prompt',
                      'negative': 'Negative Prompt',
                      'seed': 'Seed',
                      'cfg': 'CFG',
                      'steps': 'Steps',
                      'sampler_name': 'Sampler',
                      'scheduler': 'Scheduler',
                      'checkpoint': 'Checkpoint',
                      'lora': 'LoRA',
                    }.entries)
                      if (s[field.key] != null)
                        SelectableText(
                          '${field.value}\n${s[field.key] is List ? (s[field.key] as List).join(', ') : s[field.key]}',
                        ),
                  ],
                ),
              ),
            for (final e in const {
              'workflow': 'ワークフロー JSON',
              'prompt': 'APIプロンプト JSON',
            }.entries)
              if (detail[e.key] != null)
                ExpansionTile(
                  title: Text(e.value),
                  children: [SelectableText(detail[e.key])],
                ),
            OutlinedButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('生成情報を再解析'),
              onPressed: () => refresh(reanalyze: true),
            ),
          ],
        );
      },
    ),
  );
}
