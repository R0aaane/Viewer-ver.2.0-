// ignore_for_file: invalid_use_of_protected_member, file_names

part of 'detailImage.dart';

extension _DetailWidgets on _ImageDetailPageState {
  String _basename(String raw) {
    if (raw.trim().isEmpty) return raw;

    // Windows繝代せ縺ｪ繧画怙蠕後・隕∫ｴ
    if (raw.contains('\\') || raw.contains('/')) {
      var s = raw.replaceAll('\\', '/');
      final slash = s.lastIndexOf('/');
      if (slash >= 0 && slash + 1 < s.length) return s.substring(slash + 1);
      return s;
    }

    // Android縺ｮtreeUri縺ｪ縺ｩ縺ｮcontent:// 縺ｮ蝣ｴ蜷・
    try {
      var s = raw;

      // 荳牙屓縺ｻ縺ｩ蝗槭☆縲・
      for (int i = 0; i < 3; i++) {
        if (!s.contains('%')) break;
        s = Uri.decodeComponent(s);
      }

      // primary: 縺ｪ縺ｩ縺ｮ繝懊Μ繝･繝ｼ繝蜷阪ｒ關ｽ縺ｨ縺励※縺ｿ繧九・
      final colon = s.indexOf(':');
      if (colon >= 0) s = s.substring(colon + 1);

      // 譛蠕後・繝代せ隕∫ｴ縺縺・
      s = s.replaceAll('\\', '/');
      final slash = s.lastIndexOf('/');
      if (slash >= 0) s = s.substring(slash + 1);

      return s.trim().isEmpty ? raw : s.trim();
    } catch (_) {
      return raw;
    }
  }

  bool _isWideLayout(BuildContext context) =>
      MediaQuery.of(context).size.width >= 980;

  void _closeSidebar() {
    // Drawer陦ｨ遉ｺ譎ゅ・縺ｿ髢峨§繧具ｼ医ョ繧ｹ繧ｯ繝医ャ繝励・蟶ｸ險ｭ繧ｵ繧､繝峨ヰ繝ｼ縺ｧ縺ｯ pop 縺励↑縺・ｼ・
    if (!_isWideLayout(context)) {
      Navigator.pop(context);
    }
  }

  Widget _withSidebar(BuildContext context, Widget body) {
    if (_fullscreen || !_isWideLayout(context)) return body;
    return Row(
      children: [
        SizedBox(
          width: _ImageDetailPageState._kSidebarWidth,
          child: _buildSidebarPanel(),
        ),
        const VerticalDivider(width: 1),
        Expanded(child: body),
      ],
    );
  }

  Widget _sidebarHeader() {
    final title = _displayTitle;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('詳細メニュー', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _sidebarSectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  Widget _buildSidebarListView() {
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        _sidebarHeader(),
        _sidebarSectionLabel('表示設定'),
        SwitchListTile(
          title: const Text('見開き表示 (ON/OFF)'),
          value: _twoPage,
          onChanged: (v) async => _setTwoPageMode(v),
        ),
        const Divider(),
        _sidebarSectionLabel('フォルダ'),
        ListTile(
          title: Text(_folder?.raw ?? '\u672a\u9078\u629e'),
          subtitle: Text(
            !widget.repo.capabilities.canPickFolder
                ? '\u30ea\u30e2\u30fc\u30c8\u30e2\u30fc\u30c9\u3067\u306f\u73fe\u5728\u306e\u30d5\u30a9\u30eb\u30c0\u3092\u8868\u793a\u4e2d'
                : '\u8868\u793a\u3059\u308b\u30d5\u30a9\u30eb\u30c0\u306b\u5207\u308a\u66ff\u3048',
          ),
          trailing: const Icon(Icons.folder_open),
          onTap: !widget.repo.capabilities.canPickFolder
              ? null
              : () async {
                  _closeSidebar();
                  final folder = await widget.repo.pickFolder();
                  if (folder == null) return;
                  final items = await widget.repo.listMedia(folder);
                  if (!mounted) return;
                  await _saveLastFolder(folder);
                  setState(() {
                    _folder = folder;
                    _items = items;
                    _index = 0;
                    _page = 1;
                  });
                  _reloadForCurrent();
                },
        ),
      ],
    );
  }

  Drawer _buildSidebar() =>
      Drawer(child: SafeArea(child: _buildSidebarListView()));

  Widget _buildSidebarPanel() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: SafeArea(child: _buildSidebarListView()),
    );
  }

  Widget _buildDetail() {
    final item = _item;

    return Padding(
      padding: const EdgeInsets.all(12),
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _buildDetailHeader(item)),
          if (_isPdf) ...[
            const SliverToBoxAdapter(child: SizedBox(height: 12)),
            _buildPdfThumbGrid(item),
          ] else
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Text(
                  '画像はサムネイル一覧がありません',
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDetailHeader(MediaItem item) {
    return _buildModernDetailHeader(item);
    // ignore: dead_code
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _infoRow('種別', ItemNameService.kindLabel(item)),
        const SizedBox(height: 8),
        if (_isPdf) _infoRow('ページ', '$_totalPages'),
        const SizedBox(height: 8),
        _infoRow('フォルダ', _basename(item.folderRaw)),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(
              width: 64,
              child: Text('名前', style: TextStyle(color: Colors.white70)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SelectableText(
                ItemNameService.formatMediaTitle(
                  item.displayName,
                  kind: item.kind,
                ),
                style: const TextStyle(color: Colors.white),
              ),
            ),
            if (_canRenameCurrentItem)
              IconButton(
                tooltip: '名前を変更',
                icon: const Icon(Icons.edit, color: Colors.white),
                onPressed: _renameCurrentItem,
              ),
          ],
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, c) {
            final narrow = c.maxWidth < 520;

            final categoryField = DropdownButtonHideUnderline(
              child: DropdownButton<TagCategory>(
                value: _tagController.selectedCategory,
                isDense: true,
                items: const [
                  DropdownMenuItem(
                    value: TagCategory.artist,
                    child: Text('作家'),
                  ),
                  DropdownMenuItem(
                    value: TagCategory.series,
                    child: Text('シリーズ'),
                  ),
                  DropdownMenuItem(
                    value: TagCategory.mediaType,
                    child: Text('メディア種別'),
                  ),
                  DropdownMenuItem(
                    value: TagCategory.character,
                    child: Text('キャラ'),
                  ),
                  DropdownMenuItem(value: TagCategory.free, child: Text('自由')),
                ],
                onChanged: (v) async {
                  if (v == null) return;
                  setState(() => _tagController.selectedCategory = v);
                  await _loadMasterTags();
                },
              ),
            );

            final inputField = TextField(
              controller: _tagController.tagCtrl,
              decoration: const InputDecoration(
                hintText: 'タグ名を入力 / 空白は不可',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _addTagFromUi(),
            );

            final addButton = FilledButton.icon(
              onPressed: _addTagFromUi,
              icon: const Icon(Icons.add),
              label: const Text('追加'),
            );

            if (!narrow) {
              return Row(
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 180),
                    child: categoryField,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: inputField),
                  const SizedBox(width: 8),
                  addButton,
                ],
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                categoryField,
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: inputField),
                    const SizedBox(width: 8),
                    addButton,
                  ],
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 10),
        if (_tagsLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final t in _tags)
              InputChip(
                label: Text(
                  '#${t.tag.name}',
                  style: const TextStyle(color: Colors.white),
                ),
                backgroundColor: _ImageDetailPageState._uiChip,
                deleteIconColor: Colors.white70,
                onDeleted: () => _removeTagFromUi(t),
              ),
            if (_tags.isEmpty && !_tagsLoading)
              const Text(
                'タグはまだありません。',
                style: TextStyle(color: Colors.white70),
              ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            const Text('タグ候補（このカテゴリ）'),
            const SizedBox(width: 8),
            if (_masterLoading)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            const Spacer(),
            IconButton(
              tooltip: '再読み込み',
              onPressed: () => _loadMasterTags(
                contains: _tagController.masterFilterCtrl.text,
              ),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 44,
          child: TextField(
            controller: _tagController.masterFilterCtrl,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: '候補を絞り込み（部分一致）',
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: (_tagController.masterFilterCtrl.text.trim().isEmpty)
                  ? null
                  : IconButton(
                      tooltip: 'クリア',
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _tagController.masterFilterCtrl.clear();
                        _loadMasterTags();
                        setState(() {});
                      },
                    ),
            ),
            onChanged: (v) {
              _loadMasterTags(contains: v);
              setState(() {});
            },
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final t in _masterTags)
              ActionChip(
                label: Text('#${t.tag.name}'),
                onPressed: () => _addExistingMasterTag(t),
              ),
            if (_masterTags.isEmpty && !_masterLoading)
              const Text('タグ候補がありません。追加するとここに表示されます。'),
          ],
        ),
      ],
    );
  }

  Widget _buildModernDetailHeader(MediaItem item) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildCompactMetadataCard(item),
        const SizedBox(height: 12),
        _buildAssignedTagsSection(),
        const SizedBox(height: 12),
        _buildCandidateTagsSection(),
      ],
    );
  }

  Widget _buildCompactMetadataCard(MediaItem item) {
    final title = ItemNameService.formatMediaTitle(
      item.displayName,
      kind: item.kind,
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: SelectableText(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (_canRenameCurrentItem)
                IconButton(
                  tooltip: '名前を変更',
                  icon: const Icon(Icons.edit, color: Colors.white),
                  onPressed: _renameCurrentItem,
                ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildMetaPill(
                icon: item.kind == MediaKind.pdf
                    ? Icons.picture_as_pdf_outlined
                    : Icons.image_outlined,
                label: ItemNameService.kindLabel(item),
              ),
              if (_isPdf)
                _buildMetaPill(
                  icon: Icons.menu_book_outlined,
                  label: '$_totalPages ページ',
                ),
              _buildMetaPill(
                icon: Icons.folder_outlined,
                label: _basename(item.folderRaw),
              ),
              _buildMetaPill(
                icon: Icons.sell_outlined,
                label: '${_tags.length} タグ',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMetaPill({required IconData icon, required String label}) {
    return _DetailMetaPill(icon: icon, label: label);
  }

  Widget _infoRow(String k, String v) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 64,
          child: Text(k, style: const TextStyle(color: Colors.white70)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: SelectableText(v, style: const TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}

class _DetailMetaPill extends StatelessWidget {
  final IconData icon;
  final String label;

  const _DetailMetaPill({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: _ImageDetailPageState._uiChip,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Colors.white70),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
