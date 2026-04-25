import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../repository/mediaRepository.dart';

@JS('window.navigator.userAgent')
external JSString get _browserUserAgent;

@JS('window.prompt')
external JSString? _windowPrompt(JSString message, JSString initialValue);

class WebUrlImportRequest {
  final String sourceUrl;
  final UrlImportOptions options;
  final ImportMetadata importMetadata;

  const WebUrlImportRequest({
    required this.sourceUrl,
    required this.options,
    required this.importMetadata,
  });

  bool get hasAnySource => options.hasAnySource(sourceUrl);
}

class WebUrlImportSheet extends StatefulWidget {
  final String folderName;
  final String initialSourceText;

  const WebUrlImportSheet({
    super.key,
    required this.folderName,
    this.initialSourceText = '',
  });

  static Future<WebUrlImportRequest?> show(
    BuildContext context, {
    required String folderName,
    String initialSourceText = '',
  }) {
    return showModalBottomSheet<WebUrlImportRequest>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => WebUrlImportSheet(
        folderName: folderName,
        initialSourceText: initialSourceText,
      ),
    );
  }

  @override
  State<WebUrlImportSheet> createState() => _WebUrlImportSheetState();
}

class _WebUrlImportSheetState extends State<WebUrlImportSheet> {
  static const List<UrlImportCookieMode> _supportedCookieModes =
      <UrlImportCookieMode>[
        UrlImportCookieMode.auto,
        UrlImportCookieMode.none,
        UrlImportCookieMode.projectKemono,
        UrlImportCookieMode.projectCoomer,
        UrlImportCookieMode.projectCombined,
      ];

  late final TextEditingController _urlController;
  final TextEditingController _favoriteUsersController =
      TextEditingController();
  final TextEditingController _parallelDownloadsController =
      TextEditingController(text: '6');
  final List<String> _confirmedUrls = <String>[];

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
  bool _favoriteSitesCustomized = false;
  bool _hitomiPdfCustomized = false;
  bool _organizeAfterImport = false;
  bool _detailsExpanded = false;
  bool _loadingClipboard = false;
  bool _normalizingUrlInput = false;
  String _lastUrlInputText = '';
  UrlImportMediaType _mediaType = UrlImportMediaType.all;
  UrlImportCookieMode _cookieMode = UrlImportCookieMode.auto;
  _ClipboardUrlCandidate? _clipboardCandidate;

  UrlImportCookieMode get _effectiveCookieMode =>
      _supportedCookieModes.contains(_cookieMode)
      ? _cookieMode
      : UrlImportCookieMode.auto;

  bool get _useSafariPastePrompt {
    final userAgent = _browserUserAgent.toDart.toLowerCase();
    final isAppleMobileDevice =
        userAgent.contains('iphone') ||
        userAgent.contains('ipad') ||
        userAgent.contains('ipod');
    final isSafari =
        userAgent.contains('safari') &&
        !userAgent.contains('crios') &&
        !userAgent.contains('fxios') &&
        !userAgent.contains('edgios') &&
        !userAgent.contains('oprios');
    return isAppleMobileDevice && isSafari;
  }

  @override
  void initState() {
    super.initState();
    _confirmedUrls.addAll(
      _analyzeSourceUrls(
        _normalizeAdjacentUrlInput(widget.initialSourceText),
      ).validUrls,
    );
    _urlController = TextEditingController();
    _applySuggestedUrlDefaults(force: true);
    if (!_useSafariPastePrompt) {
      unawaited(_refreshClipboardCandidate());
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _favoriteUsersController.dispose();
    _parallelDownloadsController.dispose();
    super.dispose();
  }

  UrlImportOptions get _options => UrlImportOptions(
    cookieMode: _effectiveCookieMode,
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
  );

  ImportMetadata get _importMetadata =>
      ImportMetadata(organizeAfterImport: _organizeAfterImport);

  _ParsedUrlDraft get _urlDraft => _analyzeSourceUrls(_urlController.text);

  List<String> get _allSourceUrls =>
      _mergeUniqueUrls(<String>[..._confirmedUrls, ..._urlDraft.validUrls]);

  _ParsedUrlDraft get _displayUrlDraft {
    final draft = _urlDraft;
    final committedSet = _confirmedUrls.toSet();
    var duplicateCount = draft.duplicateCount;
    for (final url in draft.validUrls) {
      if (committedSet.contains(url)) {
        duplicateCount += 1;
      }
    }
    return _ParsedUrlDraft(
      validUrls: List<String>.unmodifiable(_confirmedUrls),
      duplicateCount: duplicateCount,
      invalidCount: draft.invalidCount,
      hadRawInput: draft.hadRawInput,
    );
  }

  void _applySuggestedUrlDefaults({bool force = false}) {
    final suggested = const UrlImportOptions().suggestedUiState(
      _allSourceUrls.join('\n'),
    );
    if (force || !_favoriteSitesCustomized) {
      _siteKemono = suggested.siteKemono;
      _siteCoomer = suggested.siteCoomer;
    }
    if (force || !_hitomiPdfCustomized) {
      _convertHitomiToPdf = suggested.convertHitomiToPdf;
    }
  }

  List<String> _splitCommaSeparated(String raw) {
    final values = <String>[];
    final seen = <String>{};
    for (final chunk in raw.split(',')) {
      final trimmed = chunk.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      final normalized = trimmed.toLowerCase();
      if (seen.add(normalized)) {
        values.add(trimmed);
      }
    }
    return values;
  }

  Iterable<String> _extractSourceCandidates(String raw) sync* {
    final matchedUrls = RegExp(
      r'https?://[^\s,]+',
      caseSensitive: false,
    ).allMatches(raw).map((match) => match.group(0) ?? '');
    final segments = matchedUrls.isNotEmpty
        ? matchedUrls
        : raw.split(RegExp(r'[\s,]+'));
    for (final segment in segments) {
      final trimmed = segment.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      yield trimmed;
    }
  }

  _ParsedUrlDraft _analyzeSourceUrls(String raw) {
    final validUrls = <String>[];
    final seen = <String>{};
    var duplicateCount = 0;
    var invalidCount = 0;

    for (final candidate in _extractSourceCandidates(raw)) {
      if (!_isSupportedHttpUrl(candidate)) {
        invalidCount += 1;
        continue;
      }
      if (seen.add(candidate)) {
        validUrls.add(candidate);
      } else {
        duplicateCount += 1;
      }
    }

    return _ParsedUrlDraft(
      validUrls: validUrls,
      duplicateCount: duplicateCount,
      invalidCount: invalidCount,
      hadRawInput: raw.trim().isNotEmpty,
    );
  }

  bool _isSupportedHttpUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) {
      return false;
    }
    final scheme = uri.scheme.trim().toLowerCase();
    return (scheme == 'http' || scheme == 'https') &&
        uri.host.trim().isNotEmpty;
  }

  String _normalizeAdjacentUrlInput(String raw) {
    return raw.replaceAllMapped(
      RegExp(r'(?<!^)(?<![\s,])(?=https?://)', caseSensitive: false),
      (_) => ', ',
    );
  }

  List<String> _mergeUniqueUrls(Iterable<String> urls) {
    final mergedUrls = <String>[];
    final seen = <String>{};
    for (final url in urls) {
      if (seen.add(url)) {
        mergedUrls.add(url);
      }
    }
    return mergedUrls;
  }

  int _normalizedSelectionOffset(String raw, int offset) {
    final safeOffset = offset.clamp(0, raw.length);
    return _normalizeAdjacentUrlInput(raw.substring(0, safeOffset)).length;
  }

  void _setUrlInputText(String text) {
    _normalizingUrlInput = true;
    _urlController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _normalizingUrlInput = false;
    _lastUrlInputText = text;
  }

  void _clearUrlInput() {
    _setUrlInputText('');
  }

  void _appendConfirmedUrls(List<String> incomingUrls) {
    final mergedUrls = _mergeUniqueUrls(<String>[
      ..._confirmedUrls,
      ..._urlDraft.validUrls,
      ...incomingUrls,
    ]);
    _confirmedUrls
      ..clear()
      ..addAll(mergedUrls);
    _clearUrlInput();
    _applySuggestedUrlDefaults();
  }

  bool _shouldAutoCommitInput(
    String previousText,
    String currentText,
    _ParsedUrlDraft draft,
  ) {
    if (draft.validUrls.isEmpty || draft.invalidCount > 0) {
      return false;
    }
    final insertedLength = currentText.length - previousText.length;
    return previousText.trim().isEmpty && insertedLength > 1;
  }

  void _commitPendingInputIfPossible() {
    final draft = _urlDraft;
    if (draft.validUrls.isEmpty) {
      return;
    }
    setState(() {
      _appendConfirmedUrls(draft.validUrls);
    });
  }

  void _handleUrlChanged(String raw) {
    if (_normalizingUrlInput) {
      _lastUrlInputText = raw;
      return;
    }
    final previousText = _lastUrlInputText;
    final normalized = _normalizeAdjacentUrlInput(raw);
    if (normalized != raw) {
      final selectionOffset = _normalizedSelectionOffset(
        raw,
        _urlController.selection.extentOffset,
      );
      _normalizingUrlInput = true;
      _urlController.value = TextEditingValue(
        text: normalized,
        selection: TextSelection.collapsed(offset: selectionOffset),
      );
      _normalizingUrlInput = false;
    }
    final draft = _analyzeSourceUrls(normalized);
    _lastUrlInputText = normalized;
    if (_shouldAutoCommitInput(previousText, normalized, draft)) {
      setState(() {
        _appendConfirmedUrls(draft.validUrls);
      });
      return;
    }
    setState(_applySuggestedUrlDefaults);
  }

  String _safariPastePromptInitialText() {
    final currentText = _normalizeAdjacentUrlInput(_urlController.text).trim();
    if (currentText.isEmpty) {
      return '';
    }
    if (currentText.endsWith(',') || currentText.endsWith(', ')) {
      return currentText;
    }
    return '$currentText, ';
  }

  void _pasteSourceUrlsWithSafariPrompt() {
    final pastedText = _windowPrompt(
      'Safari ではここに URL を貼り付けてください'.toJS,
      _safariPastePromptInitialText().toJS,
    )?.toDart;
    if (pastedText == null || !mounted) {
      return;
    }
    final draft = _analyzeSourceUrls(pastedText);
    if (draft.validUrls.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('貼り付けた内容に URL が見つかりませんでした')),
      );
      return;
    }
    setState(() {
      _appendConfirmedUrls(draft.validUrls);
      _clipboardCandidate = null;
    });
  }

  Future<void> _refreshClipboardCandidate() async {
    setState(() {
      _loadingClipboard = true;
    });
    try {
      final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
      final clipboardText = clipboardData?.text ?? '';
      final draft = _analyzeSourceUrls(clipboardText);
      if (!mounted) {
        return;
      }
      setState(() {
        _clipboardCandidate = draft.validUrls.isEmpty
            ? null
            : _ClipboardUrlCandidate(draft: draft);
        _loadingClipboard = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _clipboardCandidate = null;
        _loadingClipboard = false;
      });
    }
  }

  Future<void> _pasteSourceUrls() async {
    if (_useSafariPastePrompt) {
      _pasteSourceUrlsWithSafariPrompt();
      return;
    }
    try {
      final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
      final clipboardText = clipboardData?.text ?? '';
      final draft = _analyzeSourceUrls(clipboardText);
      if (!mounted) {
        return;
      }
      if (draft.validUrls.isEmpty) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('クリップボードに URL が見つかりませんでした')),
        );
        return;
      }
      setState(() {
        _appendConfirmedUrls(draft.validUrls);
        _clipboardCandidate = _ClipboardUrlCandidate(draft: draft);
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('クリップボードを読み取れませんでした')));
    }
  }

  void _removeUrl(String url) {
    final remainingUrls = _confirmedUrls
        .where((entry) => entry != url)
        .toList();
    setState(() {
      _confirmedUrls
        ..clear()
        ..addAll(remainingUrls);
      _applySuggestedUrlDefaults();
    });
  }

  List<String> _availableClipboardUrls(_ParsedUrlDraft currentDraft) {
    final candidate = _clipboardCandidate;
    if (candidate == null) {
      return const <String>[];
    }
    final currentUrls = _mergeUniqueUrls(<String>[
      ..._confirmedUrls,
      ...currentDraft.validUrls,
    ]).toSet();
    return candidate.draft.validUrls
        .where((url) => !currentUrls.contains(url))
        .toList(growable: false);
  }

  String _cookieModeLabel(UrlImportCookieMode mode) {
    switch (mode) {
      case UrlImportCookieMode.auto:
        return '自動';
      case UrlImportCookieMode.none:
        return '使わない';
      case UrlImportCookieMode.projectKemono:
        return 'ホストの Kemono Cookie';
      case UrlImportCookieMode.projectCoomer:
        return 'ホストの Coomer Cookie';
      case UrlImportCookieMode.projectCombined:
        return 'ホストの共通 Cookie';
      case UrlImportCookieMode.customFile:
        return 'カスタムファイル';
    }
  }

  String _detailsSummary() {
    final parts = <String>[_cookieModeLabel(_effectiveCookieMode)];
    if (_favoritePosts) {
      parts.add('favorite posts');
    }
    final favoriteUsers = _options.normalizedFavoriteUserServices;
    if (favoriteUsers.isNotEmpty) {
      parts.add('favorite users ${favoriteUsers.length}件');
    }
    if (_siteKemono || _siteCoomer) {
      final sites = <String>[
        if (_siteKemono) 'Kemono',
        if (_siteCoomer) 'Coomer',
      ];
      parts.add(sites.join(' / '));
    }
    if (_mediaType != UrlImportMediaType.all) {
      parts.add(_mediaTypeLabel(_mediaType));
    }
    return parts.join(' / ');
  }

  String _mediaTypeLabel(UrlImportMediaType mediaType) {
    switch (mediaType) {
      case UrlImportMediaType.all:
        return 'すべて';
      case UrlImportMediaType.images:
        return '画像のみ';
      case UrlImportMediaType.videos:
        return '動画のみ';
      case UrlImportMediaType.imagesVideos:
        return '画像と動画';
    }
  }

  String? _submitDisabledReason(_ParsedUrlDraft draft) {
    final options = _options;
    if (_allSourceUrls.isEmpty && !options.hasFavoriteTargets) {
      return draft.hadRawInput ? '有効な URL を1件以上入力してください' : 'URL を1件以上入力してください';
    }
    if (options.hasFavoriteTargets && !options.hasCookieSelection) {
      return 'favorites を使うには Cookie を選択してください';
    }
    if (options.hasFavoriteTargets && options.normalizedFavoriteSites.isEmpty) {
      return 'favorites の対象サイトを選択してください';
    }
    return null;
  }

  String _submitLabel(_ParsedUrlDraft draft) {
    final urlCount = _allSourceUrls.length;
    if (urlCount == 1) {
      return '1件を実行';
    }
    if (urlCount > 1) {
      return '${draft.validUrls.length}件を実行';
    }
    return 'ホストで実行';
  }

  void _submit() {
    final draft = _urlDraft;
    final disabledReason = _submitDisabledReason(draft);
    if (disabledReason != null) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(disabledReason)));
      return;
    }
    final sourceUrls = _allSourceUrls;
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop(
      WebUrlImportRequest(
        sourceUrl: sourceUrls.join(', '),
        options: _options,
        importMetadata: _importMetadata,
      ),
    );
  }

  InputDecoration _fieldDecoration({
    required BuildContext context,
    required String labelText,
    String? hintText,
    String? helperText,
    bool alignLabelWithHint = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: BorderSide(color: colorScheme.outline.withOpacity(0.2)),
    );
    return InputDecoration(
      labelText: labelText,
      hintText: hintText,
      helperText: helperText,
      alignLabelWithHint: alignLabelWithHint,
      filled: true,
      fillColor: colorScheme.surface.withOpacity(0.42),
      enabledBorder: border,
      border: border,
      focusedBorder: border.copyWith(
        borderSide: BorderSide(color: colorScheme.primary, width: 1.4),
      ),
    );
  }

  Widget _buildClipboardSuggestion(
    BuildContext context,
    List<String> clipboardUrls,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final candidate = _clipboardCandidate;
    final duplicateCount = candidate == null
        ? 0
        : candidate.draft.validUrls.length - clipboardUrls.length;
    return Material(
      color: colorScheme.primary.withOpacity(0.08),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () {
          setState(() {
            _appendConfirmedUrls(clipboardUrls);
          });
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.content_paste_rounded, color: colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'クリップボードの URL を貼り付け',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      duplicateCount > 0
                          ? '${clipboardUrls.length}件の URL を追加できます。重複 ${duplicateCount}件は除外します'
                          : '${clipboardUrls.length}件の URL を検出しました',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.tonal(
                onPressed: () {
                  setState(() {
                    _appendConfirmedUrls(clipboardUrls);
                  });
                },
                child: const Text('反映'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUrlRecognitionSection(
    BuildContext context,
    _ParsedUrlDraft draft,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final validUrls = draft.validUrls;
    final listChildren = validUrls
        .map(
          (url) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: colorScheme.surface.withOpacity(0.35),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: colorScheme.outline.withOpacity(0.14)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    Icons.link_rounded,
                    size: 18,
                    color: colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SelectableText(
                    url,
                    maxLines: 2,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: () => _removeUrl(url),
                  tooltip: '削除',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
        )
        .toList(growable: false);

    Widget urlList;
    if (validUrls.length > 4) {
      urlList = SizedBox(
        height: 240,
        child: ListView.separated(
          padding: EdgeInsets.zero,
          itemCount: validUrls.length,
          itemBuilder: (context, index) => listChildren[index],
          separatorBuilder: (_, __) => const SizedBox(height: 8),
        ),
      );
    } else {
      urlList = Column(
        children: [
          for (var index = 0; index < listChildren.length; index++) ...[
            if (index > 0) const SizedBox(height: 8),
            listChildren[index],
          ],
        ],
      );
    }

    return _SheetSectionCard(
      title: '認識結果',
      description: draft.hasValidUrls
          ? 'この内容でホストへ送信します'
          : '有効な URL を認識するとここに表示されます',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _StatusLine(
            icon: Icons.check_circle_outline_rounded,
            color: colorScheme.primary,
            text: '有効な URL を ${draft.validUrls.length}件認識しました',
          ),
          if (draft.duplicateCount > 0) ...[
            const SizedBox(height: 8),
            _StatusLine(
              icon: Icons.copy_all_outlined,
              color: colorScheme.secondary,
              text: '重複 ${draft.duplicateCount}件を除外しました',
            ),
          ],
          if (draft.invalidCount > 0) ...[
            const SizedBox(height: 8),
            _StatusLine(
              icon: Icons.error_outline_rounded,
              color: colorScheme.error,
              text: '無効な形式の URL が ${draft.invalidCount}件あります',
            ),
          ],
          if (draft.hasValidUrls) ...[const SizedBox(height: 14), urlList],
        ],
      ),
    );
  }

  Widget _buildDetailedSettings(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Cookie / favorites',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<UrlImportCookieMode>(
          value: _effectiveCookieMode,
          decoration: _fieldDecoration(
            context: context,
            labelText: 'Cookie モード',
          ),
          items: _supportedCookieModes
              .map(
                (mode) => DropdownMenuItem<UrlImportCookieMode>(
                  value: mode,
                  child: Text(_cookieModeLabel(mode)),
                ),
              )
              .toList(growable: false),
          onChanged: (value) {
            if (value == null) {
              return;
            }
            setState(() {
              _cookieMode = value;
            });
          },
        ),
        const SizedBox(height: 8),
        Text(
          'Web ではホスト側の project cookie を使います。favorites 実行時は Cookie と対象サイトを選んでください。',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilterChip(
              label: const Text('Kemono'),
              selected: _siteKemono,
              onSelected: (selected) {
                setState(() {
                  _favoriteSitesCustomized = true;
                  _siteKemono = selected;
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
          subtitle: const Text('URL を入力しなくてもホスト側で favorites を実行できます'),
          onChanged: (value) {
            setState(() {
              _favoritePosts = value ?? false;
            });
          },
        ),
        TextField(
          controller: _favoriteUsersController,
          onChanged: (_) => setState(() {}),
          decoration: _fieldDecoration(
            context: context,
            labelText: 'favorite users サービス',
            hintText: 'all / patreon,fanbox / onlyfans',
            helperText: '空欄なら favorite users は使いません',
          ),
        ),
        const SizedBox(height: 18),
        Text('取り込みオプション', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        DropdownButtonFormField<UrlImportMediaType>(
          value: _mediaType,
          decoration: _fieldDecoration(context: context, labelText: 'メディア種別'),
          items: const <DropdownMenuItem<UrlImportMediaType>>[
            DropdownMenuItem(value: UrlImportMediaType.all, child: Text('すべて')),
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
            if (value == null) {
              return;
            }
            setState(() {
              _mediaType = value;
            });
          },
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _parallelDownloadsController,
          keyboardType: TextInputType.number,
          onChanged: (_) => setState(() {}),
          decoration: _fieldDecoration(
            context: context,
            labelText: '並列ダウンロード数',
            helperText: '既定は 6 です',
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilterChip(
              label: const Text('Hitomi を PDF 化'),
              selected: _convertHitomiToPdf,
              onSelected: (selected) {
                setState(() {
                  _hitomiPdfCustomized = true;
                  _convertHitomiToPdf = selected;
                });
              },
            ),
            FilterChip(
              label: const Text('取り込み後に整理'),
              selected: _organizeAfterImport,
              onSelected: (selected) {
                setState(() {
                  _organizeAfterImport = selected;
                });
              },
            ),
            FilterChip(
              label: const Text('inline 画像'),
              selected: _includeInlineImages,
              onSelected: (selected) {
                setState(() {
                  _includeInlineImages = selected;
                });
              },
            ),
            FilterChip(
              label: const Text('本文保存'),
              selected: _includePostContent,
              onSelected: (selected) {
                setState(() {
                  _includePostContent = selected;
                });
              },
            ),
            FilterChip(
              label: const Text('コメント保存'),
              selected: _includeComments,
              onSelected: (selected) {
                setState(() {
                  _includeComments = selected;
                });
              },
            ),
            FilterChip(
              label: const Text('JSON 保存'),
              selected: _saveJson,
              onSelected: (selected) {
                setState(() {
                  _saveJson = selected;
                });
              },
            ),
            FilterChip(
              label: const Text('上書き'),
              selected: _overwriteExistingFiles,
              onSelected: (selected) {
                setState(() {
                  _overwriteExistingFiles = selected;
                });
              },
            ),
            FilterChip(
              label: const Text('詳細ログ'),
              selected: _verbose,
              onSelected: (selected) {
                setState(() {
                  _verbose = selected;
                });
              },
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final mediaQuery = MediaQuery.of(context);
    final bottomInset = mediaQuery.viewInsets.bottom;
    final initialChildSize = mediaQuery.size.height < 760 ? 0.76 : 0.72;
    final draft = _urlDraft;
    final displayDraft = _displayUrlDraft;
    final clipboardUrls = _availableClipboardUrls(draft);
    final disabledReason = _submitDisabledReason(draft);

    return SafeArea(
      top: false,
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: EdgeInsets.only(bottom: bottomInset),
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: initialChildSize,
          minChildSize: 0.56,
          maxChildSize: 0.96,
          builder: (context, scrollController) {
            return Align(
              alignment: Alignment.bottomCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
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
                            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _SheetSectionCard(
                                  title: '保存先',
                                  description: '取り込み先のフォルダ',
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.folder_open_outlined,
                                        color: colorScheme.primary,
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          widget.folderName,
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleMedium,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 16),
                                _SheetSectionCard(
                                  title: 'URL',
                                  description:
                                      'Hitomi / Kemono / Coomer の URL、または favorites 条件をホストで実行します。',
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Row(
                                        children: [
                                          Text(
                                            'URLを貼り付け',
                                            style: Theme.of(
                                              context,
                                            ).textTheme.titleSmall,
                                          ),
                                          const Spacer(),
                                          OutlinedButton.icon(
                                            onPressed: _pasteSourceUrls,
                                            icon: const Icon(
                                              Icons.content_paste_go_outlined,
                                            ),
                                            label: const Text('貼り付け'),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      TextField(
                                        controller: _urlController,
                                        autofocus:
                                            widget.initialSourceText
                                                .trim()
                                                .isEmpty &&
                                            !_useSafariPastePrompt,
                                        keyboardType: TextInputType.url,
                                        textInputAction: TextInputAction.done,
                                        minLines: 4,
                                        maxLines: 8,
                                        onChanged: _handleUrlChanged,
                                        onEditingComplete:
                                            _commitPendingInputIfPossible,
                                        onSubmitted: (_) =>
                                            _commitPendingInputIfPossible(),
                                        decoration: _fieldDecoration(
                                          context: context,
                                          labelText: 'URL',
                                          hintText:
                                              'URLを貼り付け\n複数URLは改行・空白・カンマ区切りで入力できます',
                                          alignLabelWithHint: true,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        '複数 URL は改行・空白・カンマ区切りで入力できます。',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color:
                                                  colorScheme.onSurfaceVariant,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (_loadingClipboard ||
                                    clipboardUrls.isNotEmpty) ...[
                                  const SizedBox(height: 16),
                                  _SheetSectionCard(
                                    title: '貼り付け候補',
                                    description: _loadingClipboard
                                        ? 'クリップボードを確認しています'
                                        : 'URL が見つかった場合はワンタップで反映できます',
                                    child: _loadingClipboard
                                        ? const LinearProgressIndicator(
                                            minHeight: 3,
                                          )
                                        : _buildClipboardSuggestion(
                                            context,
                                            clipboardUrls,
                                          ),
                                  ),
                                ],
                                if (displayDraft.hasValidUrls ||
                                    displayDraft.duplicateCount > 0 ||
                                    displayDraft.invalidCount > 0) ...[
                                  const SizedBox(height: 16),
                                  _buildUrlRecognitionSection(
                                    context,
                                    displayDraft,
                                  ),
                                ],
                                const SizedBox(height: 16),
                                _SheetSectionCard(
                                  title: '詳細設定',
                                  description:
                                      'Cookie と favorites は必要なときだけ設定できます',
                                  child: Theme(
                                    data: Theme.of(context).copyWith(
                                      dividerColor: Colors.transparent,
                                    ),
                                    child: ExpansionTile(
                                      initiallyExpanded: false,
                                      tilePadding: EdgeInsets.zero,
                                      childrenPadding: const EdgeInsets.only(
                                        top: 12,
                                      ),
                                      onExpansionChanged: (expanded) {
                                        setState(() {
                                          _detailsExpanded = expanded;
                                        });
                                      },
                                      title: const Text(
                                        'Cookie / favorites 設定',
                                      ),
                                      subtitle: Text(
                                        _detailsExpanded
                                            ? '必要な項目だけ変更してください'
                                            : _detailsSummary(),
                                      ),
                                      children: [
                                        _buildDetailedSettings(context),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      _SheetFooter(
                        disabledReason: disabledReason,
                        submitLabel: _submitLabel(
                          _ParsedUrlDraft(validUrls: _allSourceUrls),
                        ),
                        onCancel: () => Navigator.of(context).pop(),
                        onSubmit: disabledReason == null ? _submit : null,
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
}

class _ParsedUrlDraft {
  final List<String> validUrls;
  final int duplicateCount;
  final int invalidCount;
  final bool hadRawInput;

  const _ParsedUrlDraft({
    this.validUrls = const <String>[],
    this.duplicateCount = 0,
    this.invalidCount = 0,
    this.hadRawInput = false,
  });

  bool get hasValidUrls => validUrls.isNotEmpty;
  String get normalizedText => validUrls.join(', ');
}

class _ClipboardUrlCandidate {
  final _ParsedUrlDraft draft;

  const _ClipboardUrlCandidate({required this.draft});
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader();

  @override
  Widget build(BuildContext context) {
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
          Text('ホストへURL取り込み', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(
            'URL を貼って、そのままホストへ送信できます。',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _SheetSectionCard extends StatelessWidget {
  final String title;
  final String description;
  final Widget child;

  const _SheetSectionCard({
    required this.title,
    required this.description,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surface.withOpacity(0.28),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: colorScheme.outline.withOpacity(0.16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            description,
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

class _StatusLine extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;

  const _StatusLine({
    required this.icon,
    required this.color,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 18, color: color),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(text)),
      ],
    );
  }
}

class _SheetFooter extends StatelessWidget {
  final String? disabledReason;
  final String submitLabel;
  final VoidCallback onCancel;
  final VoidCallback? onSubmit;

  const _SheetFooter({
    required this.disabledReason,
    required this.submitLabel,
    required this.onCancel,
    required this.onSubmit,
  });

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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (disabledReason != null) ...[
              Text(
                disabledReason!,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colorScheme.error),
              ),
              const SizedBox(height: 10),
            ],
            Row(
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
                    icon: const Icon(Icons.download_outlined),
                    label: Text(submitLabel),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
