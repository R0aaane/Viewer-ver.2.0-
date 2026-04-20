import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../database/tag_service.dart';
import '../models/mediaItem.dart';
import '../models/tag.dart';
import '../repository/mediaRepository.dart';
import '../services/controller_navigation_service.dart';

class ImportToHostDialog {
  const ImportToHostDialog._();

  static Future<ImportRequest?> show(
    BuildContext context, {
    required TagService tagService,
    required ImportSourceKind sourceKind,
    required List<MediaItem> selectedItems,
    bool supportsHostPdfConversion = false,
  }) {
    return ImportToHostSheet.show(
      context,
      tagService: tagService,
      sourceKind: sourceKind,
      selectedItems: selectedItems,
      supportsHostPdfConversion: supportsHostPdfConversion,
    );
  }
}

class ImportToHostSheet extends StatefulWidget {
  final TagService tagService;
  final ImportSourceKind sourceKind;
  final List<MediaItem> selectedItems;
  final bool supportsHostPdfConversion;

  const ImportToHostSheet({
    super.key,
    required this.tagService,
    required this.sourceKind,
    required this.selectedItems,
    required this.supportsHostPdfConversion,
  });

  static Future<ImportRequest?> show(
    BuildContext context, {
    required TagService tagService,
    required ImportSourceKind sourceKind,
    required List<MediaItem> selectedItems,
    bool supportsHostPdfConversion = false,
  }) {
    return showControllerModalBottomSheet<ImportRequest>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.97,
        child: ImportToHostSheet(
          tagService: tagService,
          sourceKind: sourceKind,
          selectedItems: selectedItems,
          supportsHostPdfConversion: supportsHostPdfConversion,
        ),
      ),
    );
  }

  @override
  State<ImportToHostSheet> createState() => _ImportToHostSheetState();
}

enum _HostImportMode { keepFiles, convertToPdfOnHost }

class _ImportToHostSheetState extends State<ImportToHostSheet> {
  late final ImportSourceKind _sourceKind;
  var _importMode = _HostImportMode.keepFiles;
  final TextEditingController _artistController = TextEditingController();
  final TextEditingController _seriesController = TextEditingController();
  final TextEditingController _characterController = TextEditingController();
  final TextEditingController _freeTagsController = TextEditingController();
  final List<String> _artistTags = <String>[];
  final List<String> _seriesTags = <String>[];
  final List<String> _characterTags = <String>[];
  final List<String> _freeTags = <String>[];
  List<String> _artistMaster = const <String>[];
  List<String> _seriesMaster = const <String>[];
  List<String> _characterMaster = const <String>[];
  bool _loadingSuggestions = false;

  @override
  void initState() {
    super.initState();
    _sourceKind = widget.sourceKind;
    _loadSuggestions();
  }

  @override
  void dispose() {
    _artistController.dispose();
    _seriesController.dispose();
    _characterController.dispose();
    _freeTagsController.dispose();
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
      if (!mounted) {
        return;
      }
      setState(() {
        _artistMaster = artist
            .map((entry) => entry.tag.name)
            .toList(growable: false);
        _seriesMaster = series
            .map((entry) => entry.tag.name)
            .toList(growable: false);
        _characterMaster = character
            .map((entry) => entry.tag.name)
            .toList(growable: false);
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
    } finally {
      if (mounted) {
        setState(() => _loadingSuggestions = false);
      }
    }
  }

  String _tagKey(String value) => value.trim().toLowerCase();

  List<String> _parseTags(String raw) {
    final result = <String>[];
    final seen = <String>{};
    for (final entry in raw.split(RegExp(r'[,\\n\\r]+'))) {
      final trimmed = entry.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      final key = _tagKey(trimmed);
      if (seen.add(key)) {
        result.add(trimmed);
      }
    }
    return result;
  }

  bool _containsTag(List<String> source, String candidate) {
    final key = _tagKey(candidate);
    return source.any((entry) => _tagKey(entry) == key);
  }

  void _setSingleTag(
    List<String> target,
    TextEditingController controller,
    String raw,
  ) {
    final tags = _parseTags(raw);
    if (tags.isEmpty) {
      return;
    }
    setState(() {
      target
        ..clear()
        ..add(tags.first);
      controller.clear();
    });
  }

  void _addTags(
    List<String> target,
    TextEditingController controller,
    String raw,
  ) {
    final tags = _parseTags(raw);
    if (tags.isEmpty) {
      return;
    }
    setState(() {
      for (final tag in tags) {
        if (!_containsTag(target, tag)) {
          target.add(tag);
        }
      }
      controller.clear();
    });
  }

  void _removeTag(List<String> target, String tag) {
    setState(() {
      target.removeWhere((entry) => _tagKey(entry) == _tagKey(tag));
    });
  }

  List<String> _matchSuggestions({
    required List<String> source,
    required String query,
    required List<String> selectedTags,
    int limit = 12,
  }) {
    final trimmed = query.trim().toLowerCase();
    final excluded = selectedTags.map(_tagKey).toSet();
    final seen = <String>{};
    final matched = <String>[];
    for (final entry in source) {
      final tag = entry.trim();
      if (tag.isEmpty) {
        continue;
      }
      final key = _tagKey(tag);
      if (!seen.add(key) || excluded.contains(key)) {
        continue;
      }
      if (trimmed.isNotEmpty && !tag.toLowerCase().contains(trimmed)) {
        continue;
      }
      matched.add(tag);
      if (matched.length >= limit) {
        break;
      }
    }
    return matched;
  }

  String? _resolveSingleTag(
    List<String> selectedTags,
    TextEditingController controller,
  ) {
    if (selectedTags.isNotEmpty) {
      return selectedTags.first;
    }
    final pending = _parseTags(controller.text);
    return pending.isEmpty ? null : pending.first;
  }

  List<String> _resolveMultiTags(
    List<String> selectedTags,
    TextEditingController controller,
  ) {
    final merged = <String>[...selectedTags];
    for (final tag in _parseTags(controller.text)) {
      if (!_containsTag(merged, tag)) {
        merged.add(tag);
      }
    }
    return merged;
  }

  List<MediaItem> get _selectedMediaItems => widget.selectedItems
      .where((item) => item.kind != MediaKind.folder)
      .toList(growable: false);

  int get _selectedImageCount => _selectedMediaItems
      .where((item) => item.kind == MediaKind.image)
      .length;

  int get _selectedPdfCount =>
      _selectedMediaItems.where((item) => item.kind == MediaKind.pdf).length;

  int get _selectedTotalBytes => _selectedMediaItems.fold<int>(
    0,
    (sum, item) => sum + (item.sizeBytes ?? 0),
  );

  bool get _isHostPdfSelected =>
      _importMode == _HostImportMode.convertToPdfOnHost;

  String _sourceKindLabel() {
    switch (_sourceKind) {
      case ImportSourceKind.files:
        return 'ファイル';
      case ImportSourceKind.folder:
        return 'フォルダ';
    }
  }

  String _selectionName() {
    if (_sourceKind == ImportSourceKind.folder) {
      final root = _selectedSourceRootRaw();
      final label = _displayNameFromRaw(root);
      if (label.isNotEmpty) {
        return label;
      }
    }
    if (_selectedMediaItems.isEmpty) {
      return '未選択';
    }
    if (_selectedMediaItems.length == 1) {
      return _selectedMediaItems.first.displayName;
    }
    return '${_selectedMediaItems.first.displayName} ほか '
        '${_selectedMediaItems.length - 1}件';
  }

  String _selectedSourceRootRaw() {
    final candidates = _selectedMediaItems
        .map((item) => item.folderRaw.trim())
        .where((raw) => raw.isNotEmpty)
        .toList(growable: false);
    if (candidates.isEmpty) {
      return '';
    }
    final first = candidates.first;
    final allSame = candidates.every((raw) => raw == first);
    if (allSame) {
      return first;
    }
    return first;
  }

  List<String> _sourceLocations() {
    final out = <String>[];
    final seen = <String>{};
    for (final item in _selectedMediaItems) {
      final raw = item.folderRaw.trim();
      if (raw.isEmpty) {
        continue;
      }
      if (seen.add(raw)) {
        out.add(raw);
      }
    }
    return out;
  }

  String _selectionPathSummary() {
    final locations = _sourceLocations();
    if (_sourceKind == ImportSourceKind.folder) {
      return _selectedSourceRootRaw();
    }
    if (_selectedMediaItems.length == 1) {
      return _selectedMediaItems.first.id;
    }
    if (locations.length == 1) {
      return locations.first;
    }
    if (locations.isEmpty) {
      return '';
    }
    return '${locations.length} 箇所から選択';
  }

  String _displayNameFromRaw(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    final normalized = trimmed.replaceAll('\\', '/');
    final tail = normalized
        .split('/')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    if (tail.isEmpty) {
      return trimmed;
    }
    final candidate = Uri.decodeComponent(tail.last);
    final colonIndex = candidate.lastIndexOf(':');
    if (colonIndex >= 0 && colonIndex + 1 < candidate.length) {
      final afterColon = candidate.substring(colonIndex + 1).trim();
      if (afterColon.isNotEmpty) {
        return afterColon;
      }
    }
    if (!trimmed.startsWith('content://')) {
      final baseName = p.basename(trimmed);
      if (baseName.trim().isNotEmpty) {
        return baseName.trim();
      }
    }
    return candidate;
  }

  String _shortenMiddle(String text, {int maxChars = 72}) {
    final trimmed = text.trim();
    if (trimmed.length <= maxChars) {
      return trimmed;
    }
    final head = (maxChars ~/ 2) - 2;
    final tail = maxChars - head - 3;
    return '${trimmed.substring(0, head)}...'
        '${trimmed.substring(trimmed.length - tail)}';
  }

  String _formatFileSize(int? sizeBytes) {
    if (sizeBytes == null || sizeBytes <= 0) {
      return 'サイズ不明';
    }
    const units = <String>['B', 'KB', 'MB', 'GB'];
    var value = sizeBytes.toDouble();
    var unitIndex = 0;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex++;
    }
    final decimals = value >= 10 || unitIndex == 0 ? 0 : 1;
    return '${value.toStringAsFixed(decimals)} ${units[unitIndex]}';
  }

  String? _hostPdfModeDisabledReason() {
    if (_selectedImageCount == 0) {
      return '画像が含まれていないため、このモードは利用できません。';
    }
    if (_selectedPdfCount > 0) {
      return '既存PDFを含む選択では、画像だけをホスト側でPDF化する処理をまだ分けていません。';
    }
    return null;
  }

  String? _hostPdfExecutionWarning() {
    if (!_isHostPdfSelected) {
      return null;
    }
    final disabledReason = _hostPdfModeDisabledReason();
    if (disabledReason != null) {
      return disabledReason;
    }
    if (!widget.supportsHostPdfConversion) {
      return 'ホスト側PDF化APIはまだ未接続です。今は「画像のまま取り込む」で実行できます。';
    }
    return null;
  }

  int _resolvedTagCount() {
    var count = 0;
    if ((_resolveSingleTag(_artistTags, _artistController)?.trim().isNotEmpty ??
        false)) {
      count += 1;
    }
    if ((_resolveSingleTag(_seriesTags, _seriesController)?.trim().isNotEmpty ??
        false)) {
      count += 1;
    }
    count += _resolveMultiTags(_characterTags, _characterController).length;
    count += _resolveMultiTags(_freeTags, _freeTagsController).length;
    return count;
  }

  String _executionSummary() {
    final parts = <String>[];
    if (_selectedImageCount > 0) {
      parts.add('画像 $_selectedImageCount枚');
    }
    if (_selectedPdfCount > 0) {
      parts.add('PDF $_selectedPdfCount件');
    }
    if (parts.isEmpty) {
      parts.add('${_selectedMediaItems.length}件');
    }
    parts.add('ホスト側PDF化: ${_isHostPdfSelected ? 'ON' : 'OFF'}');
    parts.add('タグ ${_resolvedTagCount()}件');
    return '${parts.join(' / ')} を送信';
  }

  void _selectImportMode(_HostImportMode mode) {
    if (mode == _HostImportMode.convertToPdfOnHost &&
        _hostPdfModeDisabledReason() != null) {
      return;
    }
    setState(() => _importMode = mode);
  }

  ImportRequest _buildRequest() {
    return ImportRequest(
      sourceKind: _sourceKind,
      metadata: ImportMetadata(
        artistTag: _resolveSingleTag(_artistTags, _artistController),
        seriesTag: _resolveSingleTag(_seriesTags, _seriesController),
        characterTags: _resolveMultiTags(_characterTags, _characterController),
        freeTags: _resolveMultiTags(_freeTags, _freeTagsController),
        targetCollection: 'library',
        convertToPdfOnHost: _isHostPdfSelected,
        organizeAfterImport: false,
      ),
    );
  }

  void _submit() {
    final warning = _hostPdfExecutionWarning();
    if (warning != null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(warning)));
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop(_buildRequest());
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return SafeArea(
      top: false,
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: Material(
              color: colorScheme.surface,
              elevation: 20,
              clipBehavior: Clip.antiAlias,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(28),
              ),
              child: Column(
                children: [
                  _SheetHeader(onClose: () => Navigator.of(context).pop()),
                  Divider(
                    height: 1,
                    color: colorScheme.outline.withValues(alpha: 0.16),
                  ),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final horizontalPadding =
                            constraints.maxWidth >= 720 ? 28.0 : 20.0;
                        return Scrollbar(
                          child: SingleChildScrollView(
                            keyboardDismissBehavior:
                                ScrollViewKeyboardDismissBehavior.onDrag,
                            padding: EdgeInsets.fromLTRB(
                              horizontalPadding,
                              20,
                              horizontalPadding,
                              24,
                            ),
                            child: _buildContent(context),
                          ),
                        );
                      },
                    ),
                  ),
                  _BottomActionBar(
                    onCancel: () => Navigator.of(context).pop(),
                    onSubmit: _hostPdfExecutionWarning() == null ? _submit : null,
                    helperText: _hostPdfExecutionWarning(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSelectionSection(context),
        const SizedBox(height: 16),
        _buildImportMethodSection(context),
        const SizedBox(height: 16),
        _buildTagSection(context),
        const SizedBox(height: 16),
        _buildExecutionSection(context),
      ],
    );
  }

  Widget _buildSelectionSection(BuildContext context) {
    final previewItems = _selectedMediaItems.take(8).toList(growable: false);
    final remainingCount = _selectedMediaItems.length - previewItems.length;
    final sourceRoot = _selectedSourceRootRaw();
    final sourceLocations = _sourceLocations();

    return _SectionCard(
      title: '選択内容',
      description: '今回ホストPCへ送る元データを確認します。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _SelectionStatChip(
                icon: Icons.inventory_2_outlined,
                label: '合計 ${_selectedMediaItems.length}件',
              ),
              if (_selectedImageCount > 0)
                _SelectionStatChip(
                  icon: Icons.image_outlined,
                  label: '画像 $_selectedImageCount枚',
                ),
              if (_selectedPdfCount > 0)
                _SelectionStatChip(
                  icon: Icons.picture_as_pdf_outlined,
                  label: 'PDF $_selectedPdfCount件',
                ),
              if (_selectedTotalBytes > 0)
                _SelectionStatChip(
                  icon: Icons.data_usage_outlined,
                  label: _formatFileSize(_selectedTotalBytes),
                ),
            ],
          ),
          const SizedBox(height: 16),
          _SummaryField(label: '選択元種別', value: _sourceKindLabel()),
          const SizedBox(height: 12),
          _SummaryField(label: '選択名', value: _selectionName()),
          if (_sourceKind == ImportSourceKind.folder && sourceRoot.isNotEmpty) ...[
            const SizedBox(height: 12),
            _SummaryField(label: '選択フォルダ', value: sourceRoot),
          ],
          const SizedBox(height: 12),
          _SummaryField(
            label: 'パス / URI',
            value: _selectionPathSummary(),
          ),
          if (_sourceKind == ImportSourceKind.files &&
              sourceLocations.length > 1) ...[
            const SizedBox(height: 12),
            _SummaryField(
              label: '選択フォルダ数',
              value: '${sourceLocations.length} 箇所',
            ),
          ],
          const SizedBox(height: 16),
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              initiallyExpanded: true,
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(top: 8),
              title: const Text('選択したファイルを確認'),
              subtitle: Text(
                remainingCount > 0
                    ? '先頭 ${previewItems.length}件を表示 / 残り $remainingCount 件'
                    : '${previewItems.length}件を表示',
              ),
              children: [
                for (final item in previewItems)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _SelectedMediaTile(
                      item: item,
                      kindLabel: item.kind == MediaKind.pdf ? 'PDF' : '画像',
                      sizeLabel: _formatFileSize(item.sizeBytes),
                      pathLabel: _shortenMiddle(
                        item.id.trim().isNotEmpty ? item.id : item.folderRaw,
                      ),
                    ),
                  ),
                if (remainingCount > 0)
                  _TagPlaceholder('ほか $remainingCount 件あります。'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImportMethodSection(BuildContext context) {
    final optionDisabledReason = _hostPdfModeDisabledReason();
    final executionWarning = _hostPdfExecutionWarning();

    return _SectionCard(
      title: '取り込み方法',
      description: '画像をそのまま送るか、将来のホスト側PDF化前提で送るかを選びます。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ImportModeCard(
            title: '画像のまま取り込む',
            description: 'Android側ではPDF変換せず、選択した画像 / PDF をそのままホストへ送信します。',
            icon: Icons.cloud_upload_outlined,
            selected: _importMode == _HostImportMode.keepFiles,
            onTap: () => _selectImportMode(_HostImportMode.keepFiles),
            statusLabel: '現在の処理',
          ),
          const SizedBox(height: 12),
          _ImportModeCard(
            title: 'ホスト側でPDF化して取り込む',
            description: optionDisabledReason ??
                (widget.supportsHostPdfConversion
                    ? '画像群をPC側で1つのPDFにまとめてからライブラリへ登録します。'
                    : 'UI とフラグのみ先行実装済みです。ホスト側PDF化API接続後にそのまま有効化できます。'),
            icon: Icons.picture_as_pdf_outlined,
            selected: _importMode == _HostImportMode.convertToPdfOnHost,
            onTap: optionDisabledReason == null
                ? () => _selectImportMode(_HostImportMode.convertToPdfOnHost)
                : null,
            statusLabel: optionDisabledReason != null
                ? '対象外'
                : widget.supportsHostPdfConversion
                    ? '利用可能'
                    : '未接続',
          ),
          const SizedBox(height: 12),
          _InlineNotice(
            icon: Icons.smartphone_outlined,
            text: 'この画面では Android 端末上のローカルPDF変換は行いません。',
          ),
          if (executionWarning != null) ...[
            const SizedBox(height: 12),
            _InlineNotice(
              icon: Icons.info_outline,
              text: executionWarning,
              isWarning: true,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTagSection(BuildContext context) {
    return _SectionCard(
      title: 'タグ',
      description: '既存の取り込みタグ形式に合わせて、付与するタグを確認します。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TagEditorBlock(
            title: 'artist',
            subtitle: 'アーティストは1件まで設定します。',
            child: _TagInputSection(
              inputLabel: 'アーティスト名',
              hintText: '例: 作家名',
              addButtonLabel: '設定',
              controller: _artistController,
              selectedTags: _artistTags,
              suggestions: _matchSuggestions(
                source: _artistMaster,
                query: _artistController.text,
                selectedTags: _artistTags,
              ),
              loadingSuggestions: _loadingSuggestions,
              selectedEmptyText: 'まだ設定されていません',
              suggestionEmptyText: '候補がなければ新しいタグ名をそのまま入力できます。',
              onChanged: (_) => setState(() {}),
              onAdd: () => _setSingleTag(
                _artistTags,
                _artistController,
                _artistController.text,
              ),
              onSuggestionPressed: (value) =>
                  _setSingleTag(_artistTags, _artistController, value),
              onDeletedTag: (value) => _removeTag(_artistTags, value),
            ),
          ),
          const SizedBox(height: 16),
          _TagEditorBlock(
            title: 'series',
            subtitle: 'シリーズは1件まで設定します。',
            child: _TagInputSection(
              inputLabel: 'シリーズ名',
              hintText: '例: シリーズ名',
              addButtonLabel: '設定',
              controller: _seriesController,
              selectedTags: _seriesTags,
              suggestions: _matchSuggestions(
                source: _seriesMaster,
                query: _seriesController.text,
                selectedTags: _seriesTags,
              ),
              loadingSuggestions: _loadingSuggestions,
              selectedEmptyText: 'まだ設定されていません',
              suggestionEmptyText: '候補がなければ新しいタグ名をそのまま入力できます。',
              onChanged: (_) => setState(() {}),
              onAdd: () => _setSingleTag(
                _seriesTags,
                _seriesController,
                _seriesController.text,
              ),
              onSuggestionPressed: (value) =>
                  _setSingleTag(_seriesTags, _seriesController, value),
              onDeletedTag: (value) => _removeTag(_seriesTags, value),
            ),
          ),
          const SizedBox(height: 16),
          _TagEditorBlock(
            title: 'character',
            subtitle: 'キャラクタータグは複数追加できます。',
            child: _TagInputSection(
              inputLabel: 'キャラクタータグ',
              hintText: 'カンマ区切りで複数追加できます',
              addButtonLabel: '追加',
              controller: _characterController,
              selectedTags: _characterTags,
              suggestions: _matchSuggestions(
                source: _characterMaster,
                query: _characterController.text,
                selectedTags: _characterTags,
              ),
              loadingSuggestions: _loadingSuggestions,
              selectedEmptyText: 'まだ追加されていません',
              suggestionEmptyText: '候補がなければ新しいタグ名をそのまま入力できます。',
              onChanged: (_) => setState(() {}),
              onAdd: () => _addTags(
                _characterTags,
                _characterController,
                _characterController.text,
              ),
              onSuggestionPressed: (value) =>
                  _addTags(_characterTags, _characterController, value),
              onDeletedTag: (value) => _removeTag(_characterTags, value),
            ),
          ),
          const SizedBox(height: 16),
          _TagEditorBlock(
            title: 'free',
            subtitle: '自由タグは複数追加できます。',
            child: _TagInputSection(
              inputLabel: '自由タグ',
              hintText: 'カンマ区切りで複数追加できます',
              addButtonLabel: '追加',
              controller: _freeTagsController,
              selectedTags: _freeTags,
              suggestions: const [],
              loadingSuggestions: false,
              selectedEmptyText: 'まだ追加されていません',
              suggestionEmptyText: 'Enter または追加ボタンで自由タグを登録できます。',
              onChanged: (_) => setState(() {}),
              onAdd: () => _addTags(
                _freeTags,
                _freeTagsController,
                _freeTagsController.text,
              ),
              onSuggestionPressed: (_) {},
              onDeletedTag: (value) => _removeTag(_freeTags, value),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExecutionSection(BuildContext context) {
    return _SectionCard(
      title: '実行',
      description: 'この内容でホストPCへ取り込みます。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SummaryField(label: '送信先', value: 'ホストPC / library'),
          const SizedBox(height: 12),
          _SummaryField(label: '実行内容', value: _executionSummary()),
          if (_hostPdfExecutionWarning() != null) ...[
            const SizedBox(height: 12),
            _InlineNotice(
              icon: Icons.warning_amber_rounded,
              text: _hostPdfExecutionWarning()!,
              isWarning: true,
            ),
          ],
        ],
      ),
    );
  }
}

class _SheetHeader extends StatelessWidget {
  final VoidCallback onClose;

  const _SheetHeader({required this.onClose});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: Alignment.center,
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: colorScheme.outline.withValues(alpha: 0.36),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('ホストへ取り込み', style: textTheme.titleLarge),
                    const SizedBox(height: 6),
                    Text(
                      '選択内容、取り込み方法、タグ、実行内容を1画面で確認できます。',
                      style: textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: onClose,
                icon: const Icon(Icons.close),
                tooltip: '閉じる',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BottomActionBar extends StatelessWidget {
  final VoidCallback onCancel;
  final VoidCallback? onSubmit;
  final String? helperText;

  const _BottomActionBar({
    required this.onCancel,
    required this.onSubmit,
    this.helperText,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          top: BorderSide(color: colorScheme.outline.withValues(alpha: 0.16)),
        ),
      ),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (helperText != null && helperText!.trim().isNotEmpty) ...[
              Text(
                helperText!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.error,
                ),
              ),
              const SizedBox(height: 10),
            ],
            LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth < 460) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      FilledButton.icon(
                        onPressed: onSubmit,
                        icon: const Icon(Icons.cloud_upload_outlined),
                        label: const Text('ホストへ取り込む'),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton(
                        onPressed: onCancel,
                        child: const Text('キャンセル'),
                      ),
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: onCancel,
                        child: const Text('キャンセル'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: onSubmit,
                        icon: const Icon(Icons.cloud_upload_outlined),
                        label: const Text('ホストへ取り込む'),
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _SelectionStatChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _SelectionStatChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colorScheme.outline.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: colorScheme.primary),
          const SizedBox(width: 8),
          Text(label),
        ],
      ),
    );
  }
}

class _SelectedMediaTile extends StatelessWidget {
  final MediaItem item;
  final String kindLabel;
  final String sizeLabel;
  final String pathLabel;

  const _SelectedMediaTile({
    required this.item,
    required this.kindLabel,
    required this.sizeLabel,
    required this.pathLabel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final icon = item.kind == MediaKind.pdf
        ? Icons.picture_as_pdf_outlined
        : Icons.image_outlined;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colorScheme.outline.withValues(alpha: 0.18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: colorScheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: Icon(icon, color: colorScheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.displayName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$kindLabel / $sizeLabel',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Tooltip(
                  message: item.id.trim().isNotEmpty ? item.id : item.folderRaw,
                  child: Text(
                    pathLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final String? description;
  final Widget child;

  const _SectionCard({
    required this.title,
    this.description,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(
          alpha: theme.brightness == Brightness.dark ? 0.22 : 0.42,
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: colorScheme.outline.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleMedium),
          if (description != null) ...[
            const SizedBox(height: 4),
            Text(
              description!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

class _SummaryField extends StatelessWidget {
  final String label;
  final String value;

  const _SummaryField({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final trimmed = value.trim().isEmpty ? '未設定' : value.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        Tooltip(
          message: trimmed,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colorScheme.surface.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: colorScheme.outline.withValues(alpha: 0.18),
              ),
            ),
            child: Text(
              trimmed,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
    );
  }
}

class _ImportModeCard extends StatelessWidget {
  final String title;
  final String description;
  final IconData icon;
  final bool selected;
  final VoidCallback? onTap;
  final String statusLabel;

  const _ImportModeCard({
    required this.title,
    required this.description,
    required this.icon,
    required this.selected,
    required this.onTap,
    required this.statusLabel,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    final borderColor = selected
        ? colorScheme.primary
        : colorScheme.outline.withValues(alpha: 0.18);
    final backgroundColor = selected
        ? colorScheme.primary.withValues(alpha: 0.08)
        : colorScheme.surface.withValues(alpha: enabled ? 0.55 : 0.35);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: borderColor, width: selected ? 1.5 : 1),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: (selected ? colorScheme.primary : colorScheme.outline)
                    .withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.center,
              child: Icon(
                icon,
                color: selected
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: selected
                              ? colorScheme.primary.withValues(alpha: 0.14)
                              : colorScheme.surface,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          statusLabel,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    description,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: enabled
                              ? colorScheme.onSurfaceVariant
                              : colorScheme.onSurfaceVariant.withValues(
                                  alpha: 0.8,
                                ),
                        ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              color: selected
                  ? colorScheme.primary
                  : colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineNotice extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool isWarning;

  const _InlineNotice({
    required this.icon,
    required this.text,
    this.isWarning = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final accent = isWarning ? colorScheme.error : colorScheme.primary;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent.withValues(alpha: 0.18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: isWarning ? colorScheme.error : accent,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TagEditorBlock extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;

  const _TagEditorBlock({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.surface.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colorScheme.outline.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _TagInputSection extends StatelessWidget {
  final String inputLabel;
  final String hintText;
  final String addButtonLabel;
  final TextEditingController controller;
  final List<String> selectedTags;
  final List<String> suggestions;
  final bool loadingSuggestions;
  final String selectedEmptyText;
  final String suggestionEmptyText;
  final ValueChanged<String> onChanged;
  final VoidCallback onAdd;
  final ValueChanged<String> onSuggestionPressed;
  final ValueChanged<String> onDeletedTag;

  const _TagInputSection({
    required this.inputLabel,
    required this.hintText,
    required this.addButtonLabel,
    required this.controller,
    required this.selectedTags,
    required this.suggestions,
    required this.loadingSuggestions,
    required this.selectedEmptyText,
    required this.suggestionEmptyText,
    required this.onChanged,
    required this.onAdd,
    required this.onSuggestionPressed,
    required this.onDeletedTag,
  });

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: controller,
      onChanged: onChanged,
      onSubmitted: (_) => onAdd(),
      textInputAction: TextInputAction.done,
      minLines: 1,
      maxLines: 2,
      decoration: InputDecoration(labelText: inputLabel, hintText: hintText),
    );
    final action = OutlinedButton.icon(
      onPressed: onAdd,
      icon: const Icon(Icons.add),
      label: Text(addButtonLabel),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 480) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  field,
                  const SizedBox(height: 10),
                  Align(alignment: Alignment.centerRight, child: action),
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: field),
                const SizedBox(width: 12),
                Padding(padding: const EdgeInsets.only(top: 6), child: action),
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        Text('設定済みタグ', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        if (selectedTags.isEmpty)
          _TagPlaceholder(selectedEmptyText)
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: selectedTags
                .map(
                  (entry) => InputChip(
                    avatar: const Icon(Icons.check, size: 18),
                    label: _ChipText(entry),
                    onDeleted: () => onDeletedTag(entry),
                  ),
                )
                .toList(growable: false),
          ),
        const SizedBox(height: 16),
        Text('候補タグ', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        if (loadingSuggestions)
          const _TagLoadingState()
        else if (suggestions.isEmpty)
          _TagPlaceholder(suggestionEmptyText)
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: suggestions
                .map(
                  (entry) => ActionChip(
                    avatar: const Icon(Icons.add, size: 18),
                    label: _ChipText(entry),
                    onPressed: () => onSuggestionPressed(entry),
                  ),
                )
                .toList(growable: false),
          ),
      ],
    );
  }
}

class _TagPlaceholder extends StatelessWidget {
  final String text;

  const _TagPlaceholder(this.text);

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colorScheme.outline.withValues(alpha: 0.18)),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }
}

class _TagLoadingState extends StatelessWidget {
  const _TagLoadingState();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 10),
        Text(
          '候補を読み込み中...',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _ChipText extends StatelessWidget {
  final String text;

  const _ChipText(this.text);

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 240),
      child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}
