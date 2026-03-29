import 'package:flutter/material.dart';

import '../database/tag_service.dart';
import '../models/tag.dart';
import '../repository/mediaRepository.dart';

class ImportToHostDialog extends StatefulWidget {
  final TagService tagService;

  const ImportToHostDialog({
    super.key,
    required this.tagService,
  });

  static Future<ImportRequest?> show(
    BuildContext context, {
    required TagService tagService,
  }) {
    return showDialog<ImportRequest>(
      context: context,
      builder: (_) => ImportToHostDialog(tagService: tagService),
    );
  }

  @override
  State<ImportToHostDialog> createState() => _ImportToHostDialogState();
}

class _ImportToHostDialogState extends State<ImportToHostDialog> {
  ImportSourceKind _sourceKind = ImportSourceKind.files;

  final TextEditingController _artistController = TextEditingController();
  final TextEditingController _seriesController = TextEditingController();
  final TextEditingController _freeTagsController = TextEditingController();
  final TextEditingController _characterTagsController = TextEditingController();

  List<String> _artistMaster = const <String>[];
  List<String> _seriesMaster = const <String>[];
  List<String> _characterMaster = const <String>[];
  bool _loadingSuggestions = false;

  @override
  void initState() {
    super.initState();
    _loadSuggestions();
  }

  @override
  void dispose() {
    _artistController.dispose();
    _seriesController.dispose();
    _freeTagsController.dispose();
    _characterTagsController.dispose();
    super.dispose();
  }

  Future<void> _loadSuggestions() async {
    setState(() => _loadingSuggestions = true);
    try {
      final artist = await widget.tagService.listTagMasterByCategory(
        TagCategory.artist,
        limit: 200,
      );
      final series = await widget.tagService.listTagMasterByCategory(
        TagCategory.series,
        limit: 200,
      );
      final character = await widget.tagService.listTagMasterByCategory(
        TagCategory.character,
        limit: 200,
      );
      if (!mounted) return;
      setState(() {
        _artistMaster = artist.map((entry) => entry.tag.name).toList(growable: false);
        _seriesMaster = series.map((entry) => entry.tag.name).toList(growable: false);
        _characterMaster = character
            .map((entry) => entry.tag.name)
            .toList(growable: false);
      });
    } catch (_) {
      if (!mounted) return;
    } finally {
      if (mounted) {
        setState(() => _loadingSuggestions = false);
      }
    }
  }

  List<String> _matchSuggestions(List<String> source, String query) {
    final trimmed = query.trim().toLowerCase();
    final matched = source
        .where(
          (entry) => trimmed.isEmpty || entry.toLowerCase().contains(trimmed),
        )
        .take(8)
        .toList(growable: false);
    return matched;
  }

  List<String> _parseTags(String raw) {
    return raw
        .split(RegExp(r'[,\\n\\r]+'))
        .map((entry) => entry.trim())
        .where((entry) => entry.isNotEmpty)
        .toSet()
        .toList(growable: false);
  }

  ImportRequest _buildRequest() {
    return ImportRequest(
      sourceKind: _sourceKind,
      metadata: ImportMetadata(
        artistTag: _artistController.text.trim().isEmpty
            ? null
            : _artistController.text.trim(),
        seriesTag: _seriesController.text.trim().isEmpty
            ? null
            : _seriesController.text.trim(),
        freeTags: _parseTags(_freeTagsController.text),
        characterTags: _parseTags(_characterTagsController.text),
        targetCollection: 'library',
        organizeAfterImport: true,
      ),
    );
  }

  Widget _buildSuggestionChips({
    required List<String> source,
    required TextEditingController controller,
  }) {
    final suggestions = _matchSuggestions(source, controller.text);
    if (suggestions.isEmpty) {
      return const SizedBox.shrink();
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: suggestions
          .map(
            (entry) => ActionChip(
              label: Text(entry),
              onPressed: () {
                setState(() {
                  controller.text = entry;
                  controller.selection = TextSelection.collapsed(
                    offset: controller.text.length,
                  );
                });
              },
            ),
          )
          .toList(growable: false),
    );
  }

  Widget _buildSingleTagField({
    required String label,
    required String hint,
    required TextEditingController controller,
    required List<String> source,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: controller,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
          ),
        ),
        const SizedBox(height: 8),
        _buildSuggestionChips(source: source, controller: controller),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('ホストへ取り込み'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'クライアント側で選んだファイルまたは画像フォルダを、ホストのライブラリへ取り込みます。',
              ),
              const SizedBox(height: 12),
              SegmentedButton<ImportSourceKind>(
                segments: const <ButtonSegment<ImportSourceKind>>[
                  ButtonSegment<ImportSourceKind>(
                    value: ImportSourceKind.files,
                    icon: Icon(Icons.upload_file_outlined),
                    label: Text('複数ファイル'),
                  ),
                  ButtonSegment<ImportSourceKind>(
                    value: ImportSourceKind.folder,
                    icon: Icon(Icons.folder_open_outlined),
                    label: Text('画像フォルダ'),
                  ),
                ],
                selected: <ImportSourceKind>{_sourceKind},
                onSelectionChanged: (selection) {
                  setState(() => _sourceKind = selection.first);
                },
              ),
              const SizedBox(height: 16),
              _buildSingleTagField(
                label: 'アーティストタグ',
                hint: '例: 作家名',
                controller: _artistController,
                source: _artistMaster,
              ),
              const SizedBox(height: 12),
              _buildSingleTagField(
                label: 'シリーズタグ',
                hint: '例: シリーズ名',
                controller: _seriesController,
                source: _seriesMaster,
              ),
              const SizedBox(height: 12),
              _buildSingleTagField(
                label: 'キャラクタータグ',
                hint: 'カンマ区切りで複数指定',
                controller: _characterTagsController,
                source: _characterMaster,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _freeTagsController,
                decoration: const InputDecoration(
                  labelText: '追加タグ',
                  hintText: 'カンマ区切りで複数指定',
                ),
                minLines: 1,
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              Text(
                _loadingSuggestions
                    ? 'タグ候補を読み込み中...'
                    : '指定したタグは取り込み対象全体にまとめて付与され、取り込み後に既存の整理ルールで自動配置されます。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.pop(context, _buildRequest()),
          icon: const Icon(Icons.cloud_upload_outlined),
          label: const Text('取り込み開始'),
        ),
      ],
    );
  }
}
