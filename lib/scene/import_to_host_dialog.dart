import 'package:flutter/material.dart';

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
  }) {
    return ImportToHostSheet.show(
      context,
      tagService: tagService,
      sourceKind: sourceKind,
      selectedItems: selectedItems,
    );
  }
}

class ImportToHostSheet extends StatefulWidget {
  final TagService tagService;
  final ImportSourceKind sourceKind;
  final List<MediaItem> selectedItems;

  const ImportToHostSheet({
    super.key,
    required this.tagService,
    required this.sourceKind,
    required this.selectedItems,
  });

  static Future<ImportRequest?> show(
    BuildContext context, {
    required TagService tagService,
    required ImportSourceKind sourceKind,
    required List<MediaItem> selectedItems,
  }) {
    return showControllerModalBottomSheet<ImportRequest>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ImportToHostSheet(
        tagService: tagService,
        sourceKind: sourceKind,
        selectedItems: selectedItems,
      ),
    );
  }

  @override
  State<ImportToHostSheet> createState() => _ImportToHostSheetState();
}

class _ImportToHostSheetState extends State<ImportToHostSheet> {
  late final ImportSourceKind _sourceKind;
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
      if (!mounted) return;
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
      if (!mounted) return;
    } finally {
      if (mounted) setState(() => _loadingSuggestions = false);
    }
  }

  String _tagKey(String value) => value.trim().toLowerCase();

  List<String> _parseTags(String raw) {
    final result = <String>[];
    final seen = <String>{};
    for (final entry in raw.split(RegExp(r'[,\\n\\r]+'))) {
      final trimmed = entry.trim();
      if (trimmed.isEmpty) continue;
      final key = _tagKey(trimmed);
      if (seen.add(key)) result.add(trimmed);
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
    if (tags.isEmpty) return;
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
    if (tags.isEmpty) return;
    setState(() {
      for (final tag in tags) {
        if (!_containsTag(target, tag)) target.add(tag);
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
      if (tag.isEmpty) continue;
      final key = _tagKey(tag);
      if (!seen.add(key) || excluded.contains(key)) continue;
      if (trimmed.isNotEmpty && !tag.toLowerCase().contains(trimmed)) continue;
      matched.add(tag);
      if (matched.length >= limit) break;
    }
    return matched;
  }

  String? _resolveSingleTag(
    List<String> selectedTags,
    TextEditingController controller,
  ) {
    if (selectedTags.isNotEmpty) return selectedTags.first;
    final pending = _parseTags(controller.text);
    return pending.isEmpty ? null : pending.first;
  }

  List<String> _resolveMultiTags(
    List<String> selectedTags,
    TextEditingController controller,
  ) {
    final merged = <String>[...selectedTags];
    for (final tag in _parseTags(controller.text)) {
      if (!_containsTag(merged, tag)) merged.add(tag);
    }
    return merged;
  }

  String _sourceKindDescription() {
    switch (_sourceKind) {
      case ImportSourceKind.files:
        return '選択した複数ファイルをそのまままとめて取り込みます。';
      case ImportSourceKind.folder:
        return '画像を含むフォルダ単位で取り込み、ライブラリ向けに整理します。';
    }
  }

  String _additionalTagSummary() {
    final parts = <String>[];
    final characterCount = _resolveMultiTags(
      _characterTags,
      _characterController,
    ).length;
    final freeCount = _resolveMultiTags(_freeTags, _freeTagsController).length;
    if (characterCount > 0) parts.add('キャラクター $characterCount 件');
    if (freeCount > 0) parts.add('追加タグ $freeCount 件');
    return parts.isEmpty ? '必要なときだけ開いて設定できます。' : parts.join(' / ');
  }

  List<MediaItem> get _selectedPdfItems => widget.selectedItems
      .where((item) => item.kind == MediaKind.pdf)
      .toList(growable: false);

  int get _selectedImageCount =>
      widget.selectedItems.where((item) => item.kind == MediaKind.image).length;

  String _selectionSummary() {
    final parts = <String>['合計 ${widget.selectedItems.length} 件'];
    final pdfCount = _selectedPdfItems.length;
    if (pdfCount > 0) {
      parts.add('PDF $pdfCount 件');
    }
    if (_selectedImageCount > 0) {
      parts.add('画像 $_selectedImageCount 件');
    }
    return parts.join(' / ');
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

  ImportRequest _buildRequest() {
    return ImportRequest(
      sourceKind: _sourceKind,
      metadata: ImportMetadata(
        artistTag: _resolveSingleTag(_artistTags, _artistController),
        seriesTag: _resolveSingleTag(_seriesTags, _seriesController),
        characterTags: _resolveMultiTags(_characterTags, _characterController),
        freeTags: _resolveMultiTags(_freeTags, _freeTagsController),
        targetCollection: 'library',
        organizeAfterImport: false,
      ),
    );
  }

  void _submit() {
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
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.88,
          minChildSize: 0.56,
          maxChildSize: 0.96,
          builder: (context, scrollController) {
            return Align(
              alignment: Alignment.bottomCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Material(
                  color: colorScheme.surface,
                  elevation: 18,
                  clipBehavior: Clip.antiAlias,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(28),
                  ),
                  child: Column(
                    children: [
                      const _SheetHeader(),
                      Divider(
                        height: 1,
                        color: colorScheme.outline.withOpacity(0.16),
                      ),
                      Expanded(
                        child: Scrollbar(
                          controller: scrollController,
                          child: SingleChildScrollView(
                            controller: scrollController,
                            keyboardDismissBehavior:
                                ScrollViewKeyboardDismissBehavior.onDrag,
                            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                            child: _buildContent(context),
                          ),
                        ),
                      ),
                      _BottomActionBar(
                        onCancel: () => Navigator.of(context).pop(),
                        onSubmit: _submit,
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionCard(
          title: '取り込み方法',
          description: '取り込み対象の選択後に確認できるようにしています。',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<ImportSourceKind>(
                segments: const [
                  ButtonSegment(
                    value: ImportSourceKind.files,
                    icon: Icon(Icons.upload_file_outlined),
                    label: Text('複数ファイル'),
                  ),
                  ButtonSegment(
                    value: ImportSourceKind.folder,
                    icon: Icon(Icons.folder_open_outlined),
                    label: Text('画像フォルダ'),
                  ),
                ],
                selected: {_sourceKind},
                showSelectedIcon: false,
                onSelectionChanged: null,
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.primary.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: colorScheme.primary.withOpacity(0.18),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      _sourceKind == ImportSourceKind.files
                          ? Icons.upload_file_outlined
                          : Icons.folder_open_outlined,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '${_sourceKindDescription()}\n変更したい場合はキャンセルして選び直してください。',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _buildSelectedItemsCard(context),
        const SizedBox(height: 16),
        _SectionCard(
          title: '取り込みルール',
          description: '整理のされ方は必要なときだけ確認できます。',
          child: Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(top: 8),
              title: const Text('取り込み時の整理ルールを表示'),
              subtitle: Text(
                _sourceKind == ImportSourceKind.files
                    ? '複数ファイルを選んでも既存ルールに沿って整理します。'
                    : '画像フォルダを選んでも既存ルールに沿って整理します。',
              ),
              children: const [
                _RuleItem(
                  icon: Icons.drive_file_move_outline,
                  text: '元フォルダ階層は保持せず、ホストのライブラリ向けに整理します。',
                ),
                _RuleItem(
                  icon: Icons.sell_outlined,
                  text: 'hitomi / kemono などの階層名はタグとして扱います。',
                ),
                _RuleItem(
                  icon: Icons.person_outline,
                  text: '作者名らしき階層はアーティストタグ候補として扱います。',
                ),
                _RuleItem(
                  icon: Icons.inventory_2_outlined,
                  text: 'タグ未設定時も不明フォルダなど既存ルールに従って整理します。',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _buildArtistCard(),
        const SizedBox(height: 16),
        _buildSeriesCard(),
        const SizedBox(height: 16),
        _buildExtraTagsCard(context),
      ],
    );
  }

  Widget _buildArtistCard() => _SectionCard(
    title: 'アーティストタグ',
    description: '必要なら取り込み対象全体にまとめて付与します。',
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
      selectedEmptyText: 'まだ選択されていません',
      suggestionEmptyText: '入力すると候補を絞り込めます。',
      onChanged: (_) => setState(() {}),
      onAdd: () =>
          _setSingleTag(_artistTags, _artistController, _artistController.text),
      onSuggestionPressed: (value) =>
          _setSingleTag(_artistTags, _artistController, value),
      onDeletedTag: (value) => _removeTag(_artistTags, value),
    ),
  );

  Widget _buildSeriesCard() => _SectionCard(
    title: 'シリーズタグ',
    description: '作品名やシリーズ名をひとつ選んで付与できます。',
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
      selectedEmptyText: 'まだ選択されていません',
      suggestionEmptyText: '入力すると候補を絞り込めます。',
      onChanged: (_) => setState(() {}),
      onAdd: () =>
          _setSingleTag(_seriesTags, _seriesController, _seriesController.text),
      onSuggestionPressed: (value) =>
          _setSingleTag(_seriesTags, _seriesController, value),
      onDeletedTag: (value) => _removeTag(_seriesTags, value),
    ),
  );

  Widget _buildExtraTagsCard(BuildContext context) => _SectionCard(
    title: '追加タグ（任意）',
    description: '既存機能のキャラクタータグと自由入力タグも残しています。',
    child: Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(top: 12),
        title: const Text('キャラクタータグ・追加タグを設定'),
        subtitle: Text(_additionalTagSummary()),
        children: [
          _TagInputSection(
            inputLabel: 'キャラクタータグ',
            hintText: '複数ある場合はカンマ区切りでも追加できます',
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
            suggestionEmptyText: '候補がなければ新しいタグ名も追加できます。',
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
          const SizedBox(height: 16),
          _TagInputSection(
            inputLabel: '追加タグ',
            hintText: 'カンマ区切りで複数追加できます',
            addButtonLabel: '追加',
            controller: _freeTagsController,
            selectedTags: _freeTags,
            suggestions: const [],
            loadingSuggestions: false,
            selectedEmptyText: 'まだ追加されていません',
            suggestionEmptyText: '自由入力タグは Enter または追加ボタンで登録します。',
            onChanged: (_) => setState(() {}),
            onAdd: () => _addTags(
              _freeTags,
              _freeTagsController,
              _freeTagsController.text,
            ),
            onSuggestionPressed: (_) {},
            onDeletedTag: (value) => _removeTag(_freeTags, value),
          ),
        ],
      ),
    ),
  );

  Widget _buildSelectedItemsCard(BuildContext context) {
    final pdfItems = _selectedPdfItems;
    final previewItems = pdfItems.take(6).toList(growable: false);
    final remainingPdfCount = pdfItems.length - previewItems.length;

    return _SectionCard(
      title: '選択した取り込み対象',
      description: '取り込み開始前に、選択済みの PDF をここで見返せます。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _SelectionStatChip(
                icon: Icons.inventory_2_outlined,
                label: '合計 ${widget.selectedItems.length} 件',
              ),
              _SelectionStatChip(
                icon: Icons.picture_as_pdf_outlined,
                label: 'PDF ${pdfItems.length} 件',
              ),
              if (_selectedImageCount > 0)
                _SelectionStatChip(
                  icon: Icons.image_outlined,
                  label: '画像 $_selectedImageCount 件',
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            _selectionSummary(),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          if (pdfItems.isEmpty)
            const _TagPlaceholder('選択した取り込み対象に PDF は含まれていません。')
          else
            Theme(
              data: Theme.of(
                context,
              ).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                initiallyExpanded: true,
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(top: 8),
                title: const Text('選択した PDF を確認'),
                subtitle: Text(
                  remainingPdfCount > 0
                      ? '先頭 ${previewItems.length} 件を表示中。ほか $remainingPdfCount 件あります。'
                      : '選択済みの PDF 一覧です。',
                ),
                children: [
                  for (final item in previewItems)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _SelectedPdfTile(
                        item: item,
                        sizeLabel: _formatFileSize(item.sizeBytes),
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

class _SheetHeader extends StatelessWidget {
  const _SheetHeader();

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: Alignment.center,
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: colorScheme.outline.withOpacity(0.36),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text('ホストへ取り込み', style: textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(
            'ファイルを選び、必要ならタグを付けてライブラリへ保存します。',
            style: textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomActionBar extends StatelessWidget {
  final VoidCallback onCancel;
  final VoidCallback onSubmit;

  const _BottomActionBar({required this.onCancel, required this.onSubmit});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          top: BorderSide(color: colorScheme.outline.withOpacity(0.16)),
        ),
      ),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: Row(
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
                label: const Text('取り込み開始'),
              ),
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
        color: colorScheme.surface.withOpacity(0.5),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colorScheme.outline.withOpacity(0.18)),
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

class _SelectedPdfTile extends StatelessWidget {
  final MediaItem item;
  final String sizeLabel;

  const _SelectedPdfTile({required this.item, required this.sizeLabel});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surface.withOpacity(0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colorScheme.outline.withOpacity(0.18)),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: colorScheme.primary.withOpacity(0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.picture_as_pdf_outlined,
              color: colorScheme.primary,
            ),
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
                  sizeLabel,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
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
        color: colorScheme.surfaceVariant.withOpacity(
          theme.brightness == Brightness.dark ? 0.22 : 0.42,
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: colorScheme.outline.withOpacity(0.18)),
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

class _RuleItem extends StatelessWidget {
  final IconData icon;
  final String text;

  const _RuleItem({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
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
        Text('選択済みタグ', style: Theme.of(context).textTheme.labelLarge),
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
        border: Border.all(color: colorScheme.outline.withOpacity(0.18)),
      ),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
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
        Text('候補を読み込み中...', style: Theme.of(context).textTheme.bodySmall),
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
