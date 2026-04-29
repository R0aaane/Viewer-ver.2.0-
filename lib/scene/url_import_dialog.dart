import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../repository/mediaRepository.dart';
import '../services/controller_navigation_service.dart';
import '../services/url_import_project_cookie_store_service.dart';
import 'url_import_browser_page.dart';

class UrlImportDialogResult {
  final String sourceUrl;
  final UrlImportOptions options;

  const UrlImportDialogResult({required this.sourceUrl, required this.options});

  bool get hasAnySource => options.hasAnySource(sourceUrl);
}

class UrlImportDialog extends StatefulWidget {
  final String title;
  final String description;
  final String initialSourceText;

  const UrlImportDialog({
    super.key,
    required this.title,
    required this.description,
    this.initialSourceText = '',
  });

  static Future<UrlImportDialogResult?> show(
    BuildContext context, {
    required String title,
    required String description,
    String initialSourceText = '',
  }) {
    return showControllerDialog<UrlImportDialogResult>(
      context: context,
      builder: (_) => UrlImportDialog(
        title: title,
        description: description,
        initialSourceText: initialSourceText,
      ),
    );
  }

  static void clearBrowserSession() {
    UrlImportBrowserPage.clearSession();
  }

  @override
  State<UrlImportDialog> createState() => _UrlImportDialogState();
}

class _UrlImportDialogState extends State<UrlImportDialog> {
  final UrlImportProjectCookieStoreService _cookieStore =
      UrlImportProjectCookieStoreService();
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _urlListFileController = TextEditingController();
  final TextEditingController _cookieFileController = TextEditingController();
  final TextEditingController _favoriteUsersController =
      TextEditingController();
  final TextEditingController _parallelDownloadsController =
      TextEditingController(text: '6');

  Map<ProjectCookieProfile, ProjectCookieSlot> _projectCookieSlots =
      <ProjectCookieProfile, ProjectCookieSlot>{};
  bool _loadingCookieSlots = true;
  bool _siteKemono = true;
  bool _siteCoomer = false;
  bool _favoritePosts = false;
  bool _includeInlineImages = false;
  bool _includePostContent = false;
  bool _includeComments = false;
  bool _saveJson = false;
  bool _overwriteExistingFiles = false;
  bool _verbose = false;
  bool _convertHitomiToPdf = true;
  bool _preferHitomiOriginal = false;
  bool _favoriteSitesCustomized = false;
  bool _hitomiPdfCustomized = false;
  UrlImportMediaType _mediaType = UrlImportMediaType.all;
  UrlImportCookieMode _cookieMode = UrlImportCookieMode.auto;
  String? _validationMessage;

  @override
  void initState() {
    super.initState();
    final initialSourceText = widget.initialSourceText.trim();
    if (initialSourceText.isNotEmpty) {
      _urlController.text = initialSourceText;
    }
    _applySuggestedUrlDefaults(force: true);
    _loadProjectCookieSlots();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _urlListFileController.dispose();
    _cookieFileController.dispose();
    _favoriteUsersController.dispose();
    _parallelDownloadsController.dispose();
    super.dispose();
  }

  Future<void> _loadProjectCookieSlots() async {
    final slots = await _cookieStore.loadSlots();
    if (!mounted) return;
    setState(() {
      _projectCookieSlots = slots;
      _loadingCookieSlots = false;
    });
  }

  UrlImportOptions get _options => UrlImportOptions(
    cookieMode: _cookieMode,
    cookieFilePath: _cookieFileController.text.trim(),
    urlListFilePath: _urlListFileController.text.trim(),
    favoriteSites: <String>[
      if (_siteKemono) 'kemono',
      if (_siteCoomer) 'coomer',
    ],
    favoritePosts: _favoritePosts,
    favoriteUserServices: _splitCommaSeparated(_favoriteUsersController.text),
    mediaType: _mediaType,
    parallelDownloads:
        int.tryParse(_parallelDownloadsController.text.trim()) ?? 6,
    includeInlineImages: _includeInlineImages,
    includePostContent: _includePostContent,
    includeComments: _includeComments,
    saveJson: _saveJson,
    overwriteExistingFiles: _overwriteExistingFiles,
    verbose: _verbose,
    convertHitomiToPdf: _convertHitomiToPdf,
    preferHitomiOriginal: _preferHitomiOriginal,
  );

  bool get _canSubmit => _validate(showMessage: false);

  bool _validate({required bool showMessage}) {
    final sourceUrl = _urlController.text.trim();
    final options = _options;
    String? message;

    if (!options.hasAnySource(sourceUrl)) {
      message = 'URL、URL 一覧ファイル、またはお気に入り条件を入力してください。';
    } else if (options.usesCustomCookieFile &&
        options.normalizedCookieFilePath == null) {
      message = 'カスタム Cookie ファイルを選択してください。';
    } else if (options.hasFavoriteTargets && !options.hasCookieSelection) {
      message = 'お気に入り取得には Cookie を選択してください。';
    } else if (options.hasFavoriteTargets &&
        options.normalizedFavoriteSites.isEmpty) {
      message = 'お気に入り取得には対象サイトを 1 つ以上選択してください。';
    } else {
      final resolvedProfile = options.resolveProjectCookieProfile(sourceUrl);
      if (resolvedProfile != null &&
          !_hasProjectCookieProfile(resolvedProfile)) {
        message = 'プロジェクト Cookie が未登録です: ${_profileLabel(resolvedProfile)}';
      }
    }

    if (showMessage) {
      setState(() => _validationMessage = message);
    }
    return message == null;
  }

  bool _hasProjectCookieProfile(String key) {
    for (final entry in _projectCookieSlots.entries) {
      if (entry.key.key == key) {
        return entry.value.exists;
      }
    }
    return false;
  }

  String _profileLabel(String key) {
    for (final profile in ProjectCookieProfile.values) {
      if (profile.key == key) {
        return profile.label;
      }
    }
    return key;
  }

  void _submit() {
    if (!_validate(showMessage: true)) {
      return;
    }
    Navigator.pop(
      context,
      UrlImportDialogResult(
        sourceUrl: _urlController.text.trim(),
        options: _options,
      ),
    );
  }

  Future<void> _pickCookieFile() async {
    final file = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(label: 'Cookie files', extensions: <String>['txt']),
      ],
    );
    if (file == null) return;
    _cookieFileController.text = file.path;
    if (mounted) {
      setState(() => _validationMessage = null);
    }
  }

  Future<void> _pickUrlListFile() async {
    final file = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(
          label: 'URL list files',
          extensions: <String>['txt', 'list', 'csv'],
        ),
      ],
    );
    if (file == null) return;
    _urlListFileController.text = file.path;
    if (mounted) {
      setState(() => _validationMessage = null);
    }
  }

  List<String> _splitCommaSeparated(String raw) {
    final values = <String>[];
    final seen = <String>{};
    for (final chunk in raw.split(',')) {
      final trimmed = chunk.trim();
      if (trimmed.isEmpty) continue;
      final normalized = trimmed.toLowerCase();
      if (seen.add(normalized)) {
        values.add(trimmed);
      }
    }
    return values;
  }

  List<String> _collectSourceUrls(String raw) {
    return const UrlImportOptions().collectSourceUrls(raw);
  }

  void _applySuggestedUrlDefaults({bool force = false}) {
    final suggested = const UrlImportOptions().suggestedUiState(
      _urlController.text,
    );
    if (force || !_favoriteSitesCustomized) {
      _siteKemono = suggested.siteKemono;
      _siteCoomer = suggested.siteCoomer;
    }
    if (force || !_hitomiPdfCustomized) {
      _convertHitomiToPdf = suggested.convertHitomiToPdf;
    }
  }

  void _mergeSourceUrls(Iterable<String> incomingUrls) {
    final merged = <String>[];
    final seen = <String>{};
    for (final url in <String>[
      ..._collectSourceUrls(_urlController.text),
      ...incomingUrls,
    ]) {
      final trimmed = url.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      if (seen.add(trimmed)) {
        merged.add(trimmed);
      }
    }
    final nextText = merged.join('\n');
    _urlController.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextText.length),
    );
    _applySuggestedUrlDefaults();
  }

  Future<void> _openInAppBrowser() async {
    if (!UrlImportBrowserPage.isSupported) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('この端末では内蔵ブラウザを利用できません')));
      return;
    }

    final currentUrls = _collectSourceUrls(_urlController.text);
    final selectedUrl = await UrlImportBrowserPage.show(
      context,
      initialUrl: currentUrls.isEmpty ? null : currentUrls.first,
    );
    if (selectedUrl == null || selectedUrl.trim().isEmpty || !mounted) {
      return;
    }
    setState(() {
      _mergeSourceUrls(<String>[selectedUrl]);
      _validationMessage = null;
    });
  }

  Widget _buildFilePickerRow({
    required TextEditingController controller,
    required String labelText,
    required String hintText,
    required VoidCallback onPick,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        Expanded(
          child: TextField(
            controller: controller,
            onChanged: (_) => setState(() => _validationMessage = null),
            decoration: InputDecoration(
              labelText: labelText,
              hintText: hintText,
            ),
          ),
        ),
        const SizedBox(width: 12),
        OutlinedButton.icon(
          onPressed: onPick,
          icon: const Icon(Icons.folder_open_outlined),
          label: const Text('選択'),
        ),
      ],
    );
  }

  String _cookieModeLabel(UrlImportCookieMode mode) {
    switch (mode) {
      case UrlImportCookieMode.auto:
        return '自動';
      case UrlImportCookieMode.none:
        return '使わない';
      case UrlImportCookieMode.projectKemono:
        return 'プロジェクト Kemono';
      case UrlImportCookieMode.projectCoomer:
        return 'プロジェクト Coomer';
      case UrlImportCookieMode.projectCombined:
        return 'プロジェクト 共通';
      case UrlImportCookieMode.customFile:
        return 'カスタムファイル';
    }
  }

  String _buildProjectCookieStatusText() {
    if (_loadingCookieSlots) {
      return 'プロジェクト Cookie を確認中...';
    }
    final parts = <String>[];
    for (final profile in ProjectCookieProfile.values) {
      final slot = _projectCookieSlots[profile];
      final state = slot?.exists == true ? '設定済み' : '未設定';
      parts.add('${profile.label}: $state');
    }
    return parts.join(' / ');
  }

  @override
  Widget build(BuildContext context) {
    final detectedUrlCount = _collectSourceUrls(_urlController.text).length;
    return AlertDialog(
      title: Text(widget.title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 760),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(widget.description),
              const SizedBox(height: 16),
              TextField(
                controller: _urlController,
                autofocus: widget.initialSourceText.trim().isEmpty,
                minLines: 4,
                maxLines: 8,
                onChanged: (_) => setState(() {
                  _validationMessage = null;
                  _applySuggestedUrlDefaults();
                }),
                decoration: const InputDecoration(
                  labelText: 'URL 一覧',
                  alignLabelWithHint: true,
                  hintText:
                      '1 行 1 件、またはカンマ区切りで複数 URL を入力\nhttps://kemono...\nhttps://coomer...\nhttps://hitomi.la/...',
                  helperText: '複数 URL を一括で取り込みできます',
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  if (UrlImportBrowserPage.isSupported)
                    OutlinedButton.icon(
                      onPressed: _openInAppBrowser,
                      icon: const Icon(Icons.open_in_browser_outlined),
                      label: const Text('内蔵ブラウザで開く'),
                    ),
                  if (detectedUrlCount > 0)
                    Chip(
                      avatar: const Icon(Icons.link, size: 18),
                      label: Text('$detectedUrlCount 件の URL'),
                    ),
                ],
              ),
              if (UrlImportBrowserPage.isSupported) ...[
                const SizedBox(height: 4),
                Text(
                  'URL を実際に開いて確認したい場合は、内蔵ブラウザから現在のページを取り込み候補へ追加できます。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 12),
              _buildFilePickerRow(
                controller: _urlListFileController,
                labelText: 'URL 一覧ファイル',
                hintText: '1 行 1 URL の txt / list / csv',
                onPick: _pickUrlListFile,
              ),
              const SizedBox(height: 20),
              Text(
                'Cookie と favorites',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<UrlImportCookieMode>(
                value: _cookieMode,
                decoration: const InputDecoration(labelText: 'Cookie の使い方'),
                items: UrlImportCookieMode.values
                    .map(
                      (mode) => DropdownMenuItem(
                        value: mode,
                        child: Text(_cookieModeLabel(mode)),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    _cookieMode = value;
                    _validationMessage = null;
                  });
                },
              ),
              const SizedBox(height: 8),
              Text(
                _buildProjectCookieStatusText(),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              Text(
                'プロジェクト Cookie の登録は「メタデータ設定」から行えます。自動では URL と favorites のサイトから選択します。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (_cookieMode == UrlImportCookieMode.customFile) ...<Widget>[
                const SizedBox(height: 12),
                _buildFilePickerRow(
                  controller: _cookieFileController,
                  labelText: 'カスタム Cookie ファイル',
                  hintText: '外部の cookie.txt を使う場合',
                  onPick: _pickCookieFile,
                ),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  FilterChip(
                    label: const Text('Kemono'),
                    selected: _siteKemono,
                    onSelected: (selected) {
                      setState(() {
                        _favoriteSitesCustomized = true;
                        _siteKemono = selected;
                        _validationMessage = null;
                      });
                    },
                  ),
                  FilterChip(
                    label: const Text('Coomer'),
                    selected: _siteCoomer,
                    onSelected: (selected) {
                      setState(() {
                        _favoriteSitesCustomized = true;
                        _siteCoomer = selected;
                        _validationMessage = null;
                      });
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                value: _favoritePosts,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('favorite posts を取り込む'),
                onChanged: (value) {
                  setState(() {
                    _favoritePosts = value ?? false;
                    _validationMessage = null;
                  });
                },
              ),
              TextField(
                controller: _favoriteUsersController,
                onChanged: (_) => setState(() => _validationMessage = null),
                decoration: const InputDecoration(
                  labelText: 'favorite users サービス',
                  hintText: 'all / patreon,fanbox / onlyfans',
                  helperText: '空欄なら favorite users は使いません',
                ),
              ),
              const SizedBox(height: 20),
              Text('ダウンロード設定', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              DropdownButtonFormField<UrlImportMediaType>(
                value: _mediaType,
                decoration: const InputDecoration(labelText: 'メディア種別'),
                items: const <DropdownMenuItem<UrlImportMediaType>>[
                  DropdownMenuItem(
                    value: UrlImportMediaType.all,
                    child: Text('すべて'),
                  ),
                  DropdownMenuItem(
                    value: UrlImportMediaType.images,
                    child: Text('画像のみ'),
                  ),
                  DropdownMenuItem(
                    value: UrlImportMediaType.videos,
                    child: Text('動画のみ'),
                  ),
                  DropdownMenuItem(
                    value: UrlImportMediaType.imagesVideos,
                    child: Text('画像と動画'),
                  ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => _mediaType = value);
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _parallelDownloadsController,
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() => _validationMessage = null),
                decoration: const InputDecoration(
                  labelText: '並列ダウンロード数',
                  helperText: '既定は 6 です',
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  FilterChip(
                    label: const Text('Hitomi を PDF 化'),
                    selected: _convertHitomiToPdf,
                    onSelected: (selected) => setState(() {
                      _hitomiPdfCustomized = true;
                      _convertHitomiToPdf = selected;
                    }),
                  ),
                  FilterChip(
                    label: const Text('Hitomi original'),
                    selected: _preferHitomiOriginal,
                    onSelected: (selected) => setState(() {
                      _preferHitomiOriginal = selected;
                    }),
                  ),
                  FilterChip(
                    label: const Text('inline 画像'),
                    selected: _includeInlineImages,
                    onSelected: (selected) => setState(() {
                      _includeInlineImages = selected;
                    }),
                  ),
                  FilterChip(
                    label: const Text('本文保存'),
                    selected: _includePostContent,
                    onSelected: (selected) => setState(() {
                      _includePostContent = selected;
                    }),
                  ),
                  FilterChip(
                    label: const Text('コメント保存'),
                    selected: _includeComments,
                    onSelected: (selected) => setState(() {
                      _includeComments = selected;
                    }),
                  ),
                  FilterChip(
                    label: const Text('JSON 保存'),
                    selected: _saveJson,
                    onSelected: (selected) => setState(() {
                      _saveJson = selected;
                    }),
                  ),
                  FilterChip(
                    label: const Text('上書き'),
                    selected: _overwriteExistingFiles,
                    onSelected: (selected) => setState(() {
                      _overwriteExistingFiles = selected;
                    }),
                  ),
                  FilterChip(
                    label: const Text('詳細ログ'),
                    selected: _verbose,
                    onSelected: (selected) => setState(() {
                      _verbose = selected;
                    }),
                  ),
                ],
              ),
              if (_validationMessage != null) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  _validationMessage!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        FilledButton.icon(
          onPressed: _canSubmit ? _submit : null,
          icon: const Icon(Icons.download_outlined),
          label: const Text('取り込み開始'),
        ),
      ],
    );
  }
}
