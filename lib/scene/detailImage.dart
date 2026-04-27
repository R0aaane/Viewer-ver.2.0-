import 'dart:typed_data';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/folder.dart';
import '../models/mediaItem.dart';
import '../repository/mediaRepository.dart';

import '../database/tag_service.dart';
import '../models/tag.dart';
import '../services/app_reading_progress_service.dart';
import '../services/controller_navigation_service.dart';
import '../services/item_name_service.dart';
import '../widgets/controller_focusable.dart';
import 'widgets/scene_ui.dart';
import 'rename_item_dialog.dart';

enum ReaderFitMode { vertical, horizontal, contain }

enum _DetailMenuAction { delete }

enum _TagSuggestionTab { recommended, recent, all }

enum _TagLayoutMode { chips, list }

class _TagSuggestionEntry {
  final Tag tag;
  final int usageCount;
  final bool isRecent;

  const _TagSuggestionEntry({
    required this.tag,
    required this.usageCount,
    required this.isRecent,
  });
}

class _PrefsKeys {
  static const String lastFolderRaw = 'prefs.lastFolderRaw';
  static const String fitMode = 'prefs.readerFitMode';
  static const String twoPage = 'prefs.readerTwoPage';

  static const String favorites = 'prefs.favorites';
  static const String detailRecentTags = 'prefs.detailRecentTags.v1';
}

class ImageDetailPage extends StatefulWidget {
  final MediaRepository repo;
  final TagService tagService;
  final List<MediaItem> items;
  final int initialIndex;
  final int? initialPdfPage;

  const ImageDetailPage({
    super.key,
    required this.repo,
    required this.tagService,
    required this.items,
    required this.initialIndex,
    this.initialPdfPage,
  });

  @override
  State<ImageDetailPage> createState() => _ImageDetailPageState();
}

class _ImageDetailPageState extends State<ImageDetailPage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final AppReadingProgressService _readingProgressService =
      AppReadingProgressService();
  FolderHandle? _folder;

  late List<MediaItem> _items;
  late int _index;

  late final TabController _tab;
  late final TabController _candidateTabController;
  late final Map<_TagSuggestionTab, ScrollController>
  _candidateScrollControllers;

  int _page = 1;
  int _totalPages = 1;

  bool _twoPage = false;
  bool _fullscreen = false;
  bool _inReader = true;

  bool _isFavorite = false;
  bool _favChanged = false;
  bool _itemChanged = false;

  // tag・医ち繧ｰ・・
  List<TagWithId> _tags = const [];
  bool _tagsChanged = false;
  bool _tagEditMode = false;
  _TagLayoutMode _tagLayoutMode = _TagLayoutMode.chips;
  final TextEditingController _assignedFilterCtrl = TextEditingController();
  final Map<String, bool> _tagGroupExpanded = <String, bool>{};
  final Map<String, int> _candidateVisibleCounts = <String, int>{};

  //縲繝輔か繝ｫ繝繧・ヵ繧｡繧､繝ｫ繧貞炎髯､
  String? _libraryRootRaw;
  bool _canDeleteFromLibrary = false;

  String _normPath(String p) => p.replaceAll('/', '\\').toLowerCase();

  // 蛟呵｣徼ag縺ｮ繧ｭ繝｣繝・す繝･
  Map<TagCategory, List<TagWithId>> _masterTagsByCategory =
      <TagCategory, List<TagWithId>>{};
  bool _masterLoading = false;
  final TextEditingController _masterFilterCtrl = TextEditingController();
  Timer? _masterFilterDebounce;
  Timer? _activityPersistDebounce;
  int? _pendingInitialPdfPage;
  bool _canPersistReadingProgress = true;
  bool _hasMovedPdfPageSinceLoad = false;

  TagCategory _selectedCategory = TagCategory.free;
  final TextEditingController _tagCtrl = TextEditingController();
  bool _tagsLoading = false;
  String? _loadedTagItemId;
  bool _masterTagsInitialized = false;
  int _detailLoadVersion = 0;
  bool _recentTagsLoaded = false;
  List<Tag> _recentTags = const <Tag>[];
  bool _tagUsageLoading = false;
  String? _tagUsageScopeRaw;
  Map<String, int> _tagUsageCounts = <String, int>{};

  ReaderFitMode _fitMode = ReaderFitMode.vertical;

  Future<Uint8List>? _leftFuture;
  Future<Uint8List>? _rightFuture;

  final Map<int, Future<Uint8List>> _readerFutureCache = {};
  final Map<int, Future<Uint8List>> _thumbFutureCache = {};

  MediaItem get _item => _items[_index];
  bool get _isPdf => _item.kind == MediaKind.pdf;
  bool get _canRenameCurrentItem => widget.repo.capabilities.canRename;
  String get _displayTitle =>
      ItemNameService.formatMediaTitle(_item.displayName, kind: _item.kind);

  void _popWithResult() {
    Navigator.of(context).pop(_favChanged || _tagsChanged || _itemChanged);
  }

  static const _uiBg = Color(0xFF0F0F10);
  static const _uiBar = Color(0xFF1F1F1F);
  static const _uiChip = Color(0xFF2B2B2B);

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _items = widget.items;
    _index = widget.initialIndex;
    _page = widget.initialPdfPage ?? 1;
    _pendingInitialPdfPage = widget.initialPdfPage;

    _tab = TabController(length: 2, vsync: this);
    _candidateTabController = TabController(
      length: _TagSuggestionTab.values.length,
      vsync: this,
    );
    _candidateScrollControllers = <_TagSuggestionTab, ScrollController>{
      for (final tab in _TagSuggestionTab.values) tab: ScrollController(),
    };

    _tab.addListener(() {
      if (_tab.indexIsChanging) return;
      final inReader = _tab.index == 0;
      if (inReader != _inReader) {
        setState(() => _inReader = inReader);
      }
      if (!inReader) {
        _ensureDeferredDetailData();
      }
    });

    _initAsync();
  }

  Future<void> _initAsync() async {
    final prefs = await SharedPreferences.getInstance();
    final fitIndex = prefs.getInt(_PrefsKeys.fitMode);
    final two = prefs.getBool(_PrefsKeys.twoPage);
    if (fitIndex != null &&
        fitIndex >= 0 &&
        fitIndex < ReaderFitMode.values.length) {
      _fitMode = ReaderFitMode.values[fitIndex];
    }
    if (two != null) _twoPage = two;
    if (widget.repo.isRemoteMode) {
      _folder = FolderHandle(_item.folderRaw);
    } else {
      final raw = prefs.getString(_PrefsKeys.lastFolderRaw);
      if (raw != null && raw.isNotEmpty) {
        _folder = FolderHandle(raw);
      }
    }
    if (!mounted) return;
    setState(() {});
    _reloadForCurrent();
    unawaited(_loadLibraryContext());
  }

  Future<void> _loadLibraryContext() async {
    try {
      final lib = await widget.repo.getAppLibraryFolder();
      if (!mounted) return;
      setState(() {
        _libraryRootRaw = lib.raw;
        _canDeleteFromLibrary = widget.repo.capabilities.canDelete && _isPdf;
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _activityPersistDebounce?.cancel();
    _masterFilterDebounce?.cancel();
    unawaited(_persistCurrentActivity());
    _assignedFilterCtrl.dispose();
    _masterFilterCtrl.dispose();
    _tagCtrl.dispose();
    for (final controller in _candidateScrollControllers.values) {
      controller.dispose();
    }
    _candidateTabController.dispose();
    _tab.dispose();
    if (_fullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_persistCurrentActivity(force: true));
    }
  }

  Future<void> _saveFitMode(ReaderFitMode v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_PrefsKeys.fitMode, v.index);
  }

  Future<void> _saveTwoPage(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_PrefsKeys.twoPage, v);
  }

  Future<void> _setTwoPageMode(bool value) async {
    if (_twoPage == value) {
      return;
    }
    setState(() {
      _twoPage = value;
      _syncReaderFutures(_item);
    });
    await _saveTwoPage(value);
  }

  bool _isCurrentLoad(int loadVersion, MediaItem item) {
    return mounted && loadVersion == _detailLoadVersion && _item.id == item.id;
  }

  void _ensureDeferredDetailData() {
    if (_loadedTagItemId != _item.id && !_tagsLoading) {
      unawaited(_loadTagsForCurrent());
    }
    if (!_masterTagsInitialized && !_masterLoading) {
      _masterTagsInitialized = true;
      unawaited(_loadMasterTags());
    }
    if (!_recentTagsLoaded) {
      _recentTagsLoaded = true;
      unawaited(_loadRecentTags());
    }
    if (_tagUsageScopeRaw != _item.folderRaw && !_tagUsageLoading) {
      unawaited(_loadTagUsageCountsForCurrentFolder());
    }
  }

  Future<void> _loadFavoriteForCurrent({int? loadVersion}) async {
    final item = _item;
    final version = loadVersion ?? _detailLoadVersion;
    final prefs = await SharedPreferences.getInstance();
    var favList = prefs.getStringList(_PrefsKeys.favorites) ?? const <String>[];
    final remoteFavorites = await widget.tagService
        .listRemoteFavoriteIds()
        .catchError((_) => null);
    if (remoteFavorites != null) {
      favList = remoteFavorites.toList(growable: false);
      await prefs.setStringList(_PrefsKeys.favorites, favList);
    }
    final lookupIds = await widget.tagService.favoriteLookupIdsForItem(item);
    final fav = lookupIds.any(favList.contains);
    if (!_isCurrentLoad(version, item)) return;
    setState(() => _isFavorite = fav);
  }

  Future<void> _toggleFavorite() async {
    final prefs = await SharedPreferences.getInstance();
    final favList =
        prefs.getStringList(_PrefsKeys.favorites) ?? const <String>[];
    final next = favList.toSet();
    final lookupIds = await widget.tagService.favoriteLookupIdsForItem(_item);
    final wasFavorite = lookupIds.any(next.contains);

    if (wasFavorite) {
      next.removeAll(lookupIds);
      setState(() => _isFavorite = false);
    } else {
      next.add(_item.id);
      setState(() => _isFavorite = true);
    }

    _favChanged = true;
    final remoteId = await widget.tagService
        .setRemoteFavorite(_item, !wasFavorite)
        .catchError((_) => null);
    if (remoteId != null && remoteId != _item.id) {
      if (next.remove(_item.id)) {
        next.add(remoteId);
      }
    }
    await prefs.setStringList(
      _PrefsKeys.favorites,
      next.toList(growable: false),
    );
  }

  Future<void> _saveLastFolder(FolderHandle folder) async {
    if (widget.repo.isRemoteMode) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_PrefsKeys.lastFolderRaw, folder.raw);
  }

  // ----------------
  // Tags (SharedPreferences萓晏ｭ・

  String? _normalizeTag(String input) {
    var t = input.trim();
    if (t.isEmpty) return null;
    if (t.startsWith('#')) t = t.substring(1);
    t = t.trim();
    if (t.isEmpty) return null;
    // 遨ｺ逋ｽ縺ｯ遖∵ｭ｢
    if (t.contains(RegExp(r'\s'))) return null;
    return t;
  }

  Future<void> _loadMasterTags({String? contains}) async {
    _masterTagsInitialized = true;
    setState(() => _masterLoading = true);
    try {
      final futures = TagCategory.values.map((category) async {
        final list = await widget.tagService.listTagMasterByCategory(
          category,
          contains: contains,
          limit: 400,
        );
        return MapEntry(category, _sortTagWithIdList(list));
      });
      final loaded = await Future.wait(futures);
      if (!mounted) return;
      setState(() {
        _masterTagsByCategory = <TagCategory, List<TagWithId>>{
          for (final entry in loaded) entry.key: entry.value,
        };
      });
    } finally {
      if (mounted) setState(() => _masterLoading = false);
    }
  }

  void _scheduleMasterTagReload(String rawQuery) {
    _masterFilterDebounce?.cancel();
    _masterFilterDebounce = Timer(const Duration(milliseconds: 240), () {
      final query = rawQuery.trim();
      unawaited(_loadMasterTags(contains: query.isEmpty ? null : query));
    });
  }

  Future<void> _loadRecentTags() async {
    final prefs = await SharedPreferences.getInstance();
    final rawEntries =
        prefs.getStringList(_PrefsKeys.detailRecentTags) ?? const <String>[];
    final decoded = <Tag>[];
    final seen = <String>{};
    for (final raw in rawEntries) {
      final tag = _deserializeRecentTag(raw);
      if (tag == null) {
        continue;
      }
      final key = _tagLookupKey(tag);
      if (key == null || !seen.add(key)) {
        continue;
      }
      decoded.add(tag);
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _recentTags = decoded;
    });
  }

  String _serializeRecentTag(Tag tag) =>
      '${tag.category.name}\u0001${tag.name}';

  Tag? _deserializeRecentTag(String raw) {
    final separatorIndex = raw.indexOf('\u0001');
    if (separatorIndex <= 0 || separatorIndex >= raw.length - 1) {
      return null;
    }
    final categoryRaw = raw.substring(0, separatorIndex);
    final name = raw.substring(separatorIndex + 1).trim();
    if (name.isEmpty) {
      return null;
    }
    TagCategory? category;
    for (final candidate in TagCategory.values) {
      if (candidate.name == categoryRaw) {
        category = candidate;
        break;
      }
    }
    if (category == null) {
      return null;
    }
    return Tag(name: name, category: category);
  }

  Future<void> _recordRecentTag(Tag tag) async {
    final key = _tagLookupKey(tag);
    if (key == null) {
      return;
    }

    final next = <Tag>[tag];
    for (final existing in _recentTags) {
      final existingKey = _tagLookupKey(existing);
      if (existingKey == null || existingKey == key) {
        continue;
      }
      next.add(existing);
      if (next.length >= 30) {
        break;
      }
    }

    if (mounted) {
      setState(() {
        _recentTags = next;
      });
    } else {
      _recentTags = next;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _PrefsKeys.detailRecentTags,
      next.map(_serializeRecentTag).toList(growable: false),
    );
  }

  Future<void> _loadTagUsageCountsForCurrentFolder() async {
    final scopeRaw = _item.folderRaw;
    _tagUsageScopeRaw = scopeRaw;
    if (mounted) {
      setState(() => _tagUsageLoading = true);
    } else {
      _tagUsageLoading = true;
    }

    try {
      final loaded = await widget.repo.listMediaRecursiveFiles(
        FolderHandle(scopeRaw),
      );
      final items = loaded
          .where((entry) => entry.kind != MediaKind.folder)
          .toList(growable: false);
      if (items.isEmpty) {
        if (!mounted || _tagUsageScopeRaw != scopeRaw) {
          return;
        }
        setState(() {
          _tagUsageCounts = <String, int>{};
        });
        return;
      }

      widget.tagService.rememberItems(items);
      final details = await widget.tagService.getDetailedTagsByItems(items);
      final counts = <String, int>{};
      for (final tags in details.values) {
        final seenInItem = <String>{};
        for (final entry in tags) {
          final key = _tagLookupKey(entry.tag);
          if (key == null || !seenInItem.add(key)) {
            continue;
          }
          counts[key] = (counts[key] ?? 0) + 1;
        }
      }

      if (!mounted || _tagUsageScopeRaw != scopeRaw) {
        return;
      }
      setState(() {
        _tagUsageCounts = counts;
      });
    } catch (_) {
      if (!mounted || _tagUsageScopeRaw != scopeRaw) {
        return;
      }
      setState(() {
        _tagUsageCounts = <String, int>{};
      });
    } finally {
      if (mounted && _tagUsageScopeRaw == scopeRaw) {
        setState(() => _tagUsageLoading = false);
      } else if (_tagUsageScopeRaw == scopeRaw) {
        _tagUsageLoading = false;
      }
    }
  }

  String? _tagLookupKey(Tag tag) {
    final normalizedName = tag.name.trim();
    if (normalizedName.isEmpty) {
      return null;
    }
    return '${tag.category.name}\u0000${normalizedName.toLowerCase()}';
  }

  Future<void> _loadTagsForCurrent({
    bool force = false,
    int? loadVersion,
  }) async {
    final item = _item;
    final version = loadVersion ?? _detailLoadVersion;
    if (!force && _loadedTagItemId == item.id) {
      return;
    }

    setState(() {
      _tagsLoading = true;
      if (_loadedTagItemId != item.id) {
        _tags = const [];
      }
    });
    try {
      final list = await widget.tagService.listTagsForItem(item.id, item: item);
      if (!_isCurrentLoad(version, item)) return;
      setState(() {
        _tags = list;
        _loadedTagItemId = item.id;
      });
    } finally {
      if (_isCurrentLoad(version, item)) {
        setState(() => _tagsLoading = false);
      }
    }
  }

  Future<void> _addSuggestedTag(Tag tag) async {
    try {
      await widget.tagService.addTagToItem(_item, tag);
      _tagsChanged = true;
      await _recordRecentTag(tag);
      await _loadTagsForCurrent(force: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('タグ追加に失敗しました: $e')));
    }
  }

  Future<void> _addTagFromUi() async {
    final raw = _tagCtrl.text;
    final name = _normalizeTag(raw);
    if (name == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('タグ名が無効です（空白を含めずに入力してください）')),
      );
      return;
    }

    final tag = Tag(name: name, category: _selectedCategory);

    try {
      await widget.tagService.addTagToItem(_item, tag);

      _tagsChanged = true;
      await _recordRecentTag(tag);
      _tagCtrl.clear();
      await _loadTagsForCurrent(force: true);
      unawaited(
        _loadMasterTags(
          contains: _masterFilterCtrl.text.trim().isEmpty
              ? null
              : _masterFilterCtrl.text.trim(),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('タグ追加に失敗しました: $e')));
    }
  }

  Future<void> _removeTagFromUi(TagWithId t) async {
    try {
      await widget.tagService.removeTagFromItem(_item.id, t.tagId, item: _item);
      _tagsChanged = true;
      await _loadTagsForCurrent(force: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('タグ削除に失敗しました: $e')));
    }
  }

  List<TagCategory> get _orderedTagCategories => const <TagCategory>[
    TagCategory.artist,
    TagCategory.series,
    TagCategory.character,
    TagCategory.mediaType,
    TagCategory.free,
  ];

  int _categoryOrder(TagCategory category) {
    return _orderedTagCategories.indexOf(category);
  }

  String _categoryLabel(TagCategory category) {
    switch (category) {
      case TagCategory.artist:
        return 'artist';
      case TagCategory.series:
        return 'series';
      case TagCategory.mediaType:
        return 'source';
      case TagCategory.character:
        return 'character';
      case TagCategory.free:
        return 'free';
    }
  }

  String _categoryLongLabel(TagCategory category) {
    switch (category) {
      case TagCategory.artist:
        return 'artist';
      case TagCategory.series:
        return 'series';
      case TagCategory.mediaType:
        return 'source / media';
      case TagCategory.character:
        return 'character';
      case TagCategory.free:
        return 'free';
    }
  }

  IconData _categoryIcon(TagCategory category) {
    switch (category) {
      case TagCategory.artist:
        return Icons.palette_outlined;
      case TagCategory.series:
        return Icons.collections_bookmark_outlined;
      case TagCategory.mediaType:
        return Icons.public_outlined;
      case TagCategory.character:
        return Icons.face_retouching_natural_outlined;
      case TagCategory.free:
        return Icons.sell_outlined;
    }
  }

  Color _categoryColor(TagCategory category) {
    switch (category) {
      case TagCategory.artist:
        return const Color(0xFFE0A15A);
      case TagCategory.series:
        return const Color(0xFF53B889);
      case TagCategory.mediaType:
        return const Color(0xFF4CA3D9);
      case TagCategory.character:
        return const Color(0xFF6D8CFF);
      case TagCategory.free:
        return const Color(0xFFC987A6);
    }
  }

  List<TagWithId> _sortTagWithIdList(Iterable<TagWithId> source) {
    final sorted = source.toList(growable: true);
    sorted.sort((left, right) {
      final categoryCompare = _categoryOrder(
        left.tag.category,
      ).compareTo(_categoryOrder(right.tag.category));
      if (categoryCompare != 0) {
        return categoryCompare;
      }
      return left.tag.name.toLowerCase().compareTo(
        right.tag.name.toLowerCase(),
      );
    });
    return sorted;
  }

  List<TagWithId> _filteredAssignedTags() {
    final query = _assignedFilterCtrl.text.trim().toLowerCase();
    final filtered = _tags.where((entry) {
      if (query.isEmpty) {
        return true;
      }
      return entry.tag.name.toLowerCase().contains(query) ||
          _categoryLabel(entry.tag.category).contains(query);
    });
    return _sortTagWithIdList(filtered);
  }

  Map<TagCategory, List<TagWithId>> _groupAssignedTags() {
    final grouped = <TagCategory, List<TagWithId>>{};
    for (final entry in _filteredAssignedTags()) {
      grouped.putIfAbsent(entry.tag.category, () => <TagWithId>[]).add(entry);
    }
    return grouped;
  }

  int _tagUsageCount(Tag tag) {
    final key = _tagLookupKey(tag);
    if (key == null) {
      return 0;
    }
    return _tagUsageCounts[key] ?? 0;
  }

  bool _matchesMasterFilter(Tag tag) {
    final query = _masterFilterCtrl.text.trim().toLowerCase();
    if (query.isEmpty) {
      return true;
    }
    return tag.name.toLowerCase().contains(query) ||
        _categoryLabel(tag.category).contains(query);
  }

  int _tagNameMatchRank(Tag tag) {
    final query = _masterFilterCtrl.text.trim().toLowerCase();
    if (query.isEmpty) {
      return 2;
    }
    final name = tag.name.toLowerCase();
    if (name == query) {
      return 0;
    }
    if (name.startsWith(query)) {
      return 1;
    }
    return 2;
  }

  List<_TagSuggestionEntry> _buildSuggestionEntries(_TagSuggestionTab tab) {
    final assignedKeys = _tags
        .map((entry) => _tagLookupKey(entry.tag))
        .whereType<String>()
        .toSet();
    final recentOrder = <String, int>{};
    for (var index = 0; index < _recentTags.length; index++) {
      final key = _tagLookupKey(_recentTags[index]);
      if (key != null && !recentOrder.containsKey(key)) {
        recentOrder[key] = index;
      }
    }

    final deduped = <String, _TagSuggestionEntry>{};

    void addTag(Tag tag) {
      if (!_matchesMasterFilter(tag)) {
        return;
      }
      final key = _tagLookupKey(tag);
      if (key == null || assignedKeys.contains(key)) {
        return;
      }
      final candidate = _TagSuggestionEntry(
        tag: tag,
        usageCount: _tagUsageCount(tag),
        isRecent: recentOrder.containsKey(key),
      );
      final existing = deduped[key];
      if (existing == null ||
          existing.usageCount < candidate.usageCount ||
          (!existing.isRecent && candidate.isRecent)) {
        deduped[key] = candidate;
      }
    }

    for (final category in _orderedTagCategories) {
      final entries = _masterTagsByCategory[category] ?? const <TagWithId>[];
      for (final entry in entries) {
        addTag(entry.tag);
      }
    }
    for (final tag in _recentTags) {
      addTag(tag);
    }

    final allEntries = deduped.values.toList(growable: true);
    final assignedCategories = _tags.map((entry) => entry.tag.category).toSet();

    List<_TagSuggestionEntry> filtered;
    switch (tab) {
      case _TagSuggestionTab.recent:
        filtered = allEntries
            .where((entry) => entry.isRecent)
            .toList(growable: true);
        break;
      case _TagSuggestionTab.all:
        filtered = allEntries;
        break;
      case _TagSuggestionTab.recommended:
        filtered = allEntries
            .where((entry) {
              return entry.isRecent ||
                  entry.usageCount > 0 ||
                  entry.tag.category == _selectedCategory ||
                  assignedCategories.contains(entry.tag.category);
            })
            .toList(growable: true);
        if (filtered.isEmpty) {
          filtered = allEntries;
        }
        break;
    }

    filtered.sort((left, right) {
      final categoryCompare = _categoryOrder(
        left.tag.category,
      ).compareTo(_categoryOrder(right.tag.category));
      if (categoryCompare != 0) {
        return categoryCompare;
      }

      final matchCompare = _tagNameMatchRank(
        left.tag,
      ).compareTo(_tagNameMatchRank(right.tag));
      if (matchCompare != 0) {
        return matchCompare;
      }

      if (tab == _TagSuggestionTab.recent) {
        final leftRecent = recentOrder[_tagLookupKey(left.tag)] ?? 999999;
        final rightRecent = recentOrder[_tagLookupKey(right.tag)] ?? 999999;
        final recentCompare = leftRecent.compareTo(rightRecent);
        if (recentCompare != 0) {
          return recentCompare;
        }
      } else {
        final leftSelected = left.tag.category == _selectedCategory ? 1 : 0;
        final rightSelected = right.tag.category == _selectedCategory ? 1 : 0;
        final selectedCompare = rightSelected.compareTo(leftSelected);
        if (selectedCompare != 0 && tab == _TagSuggestionTab.recommended) {
          return selectedCompare;
        }

        final leftAssigned = assignedCategories.contains(left.tag.category)
            ? 1
            : 0;
        final rightAssigned = assignedCategories.contains(right.tag.category)
            ? 1
            : 0;
        final assignedCompare = rightAssigned.compareTo(leftAssigned);
        if (assignedCompare != 0 && tab == _TagSuggestionTab.recommended) {
          return assignedCompare;
        }

        final recentCompare = (right.isRecent ? 1 : 0).compareTo(
          left.isRecent ? 1 : 0,
        );
        if (recentCompare != 0 && tab == _TagSuggestionTab.recommended) {
          return recentCompare;
        }

        final usageCompare = right.usageCount.compareTo(left.usageCount);
        if (usageCompare != 0) {
          return usageCompare;
        }
      }

      return left.tag.name.toLowerCase().compareTo(
        right.tag.name.toLowerCase(),
      );
    });
    return filtered;
  }

  Map<TagCategory, List<_TagSuggestionEntry>> _groupSuggestionEntries(
    _TagSuggestionTab tab,
  ) {
    final grouped = <TagCategory, List<_TagSuggestionEntry>>{};
    for (final entry in _buildSuggestionEntries(tab)) {
      grouped
          .putIfAbsent(entry.tag.category, () => <_TagSuggestionEntry>[])
          .add(entry);
    }
    return grouped;
  }

  bool _isGroupExpanded(String key, {required bool defaultValue}) {
    return _tagGroupExpanded[key] ?? defaultValue;
  }

  void _toggleGroupExpanded(String key, {required bool defaultValue}) {
    setState(() {
      _tagGroupExpanded[key] = !(_tagGroupExpanded[key] ?? defaultValue);
    });
  }

  int _visibleCandidateCount(
    _TagSuggestionTab tab,
    TagCategory category,
    int total,
  ) {
    final key = '${tab.name}:${category.name}';
    final count = _candidateVisibleCounts[key] ?? 12;
    return count > total ? total : count;
  }

  void _showMoreCandidates(_TagSuggestionTab tab, TagCategory category) {
    final key = '${tab.name}:${category.name}';
    setState(() {
      _candidateVisibleCounts[key] = (_candidateVisibleCounts[key] ?? 12) + 12;
    });
  }

  BoxFit get _boxFit {
    switch (_fitMode) {
      case ReaderFitMode.vertical:
        return BoxFit.fitHeight;
      case ReaderFitMode.horizontal:
        return BoxFit.fitWidth;
      case ReaderFitMode.contain:
        return BoxFit.contain;
    }
  }

  Future<Uint8List> _loadReaderBytes(MediaItem item, int page) {
    return _readerFutureCache.putIfAbsent(page, () {
      return widget.repo.renderPageBytes(item, page, maxWidth: 1600);
    });
  }

  Future<Uint8List> _loadThumbBytes(MediaItem item, int page) {
    return _thumbFutureCache.putIfAbsent(page, () {
      return widget.repo.renderPageBytes(item, page, maxWidth: 320);
    });
  }

  void _syncReaderFutures(MediaItem item) {
    _leftFuture = _loadReaderBytes(item, _page);

    if (_twoPage && _isPdf) {
      final nextPage = _page + 1;
      _rightFuture = nextPage <= _totalPages
          ? _loadReaderBytes(item, nextPage)
          : null;
      return;
    }

    _rightFuture = null;
  }

  void _setCurrentPdfPage(int page) {
    setState(() {
      _hasMovedPdfPageSinceLoad = true;
      _page = page.clamp(1, _totalPages);
      _syncReaderFutures(_item);
    });
    _schedulePersistCurrentActivity();
  }

  Future<void> _loadPageCountForCurrent(MediaItem item, int loadVersion) async {
    try {
      final total = await widget.repo.getPageCount(item);
      if (!_isCurrentLoad(loadVersion, item)) return;

      setState(() {
        _totalPages = total < 1 ? 1 : total;
        _page = _page.clamp(1, _totalPages);
        _syncReaderFutures(item);
      });
      _schedulePersistCurrentActivity();
    } catch (error) {
      if (!_isCurrentLoad(loadVersion, item)) return;
      setState(() {
        _totalPages = 1;
        _page = 1;
        _syncReaderFutures(item);
      });
      _schedulePersistCurrentActivity();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('ページ情報の取得に失敗しました: $error')));
    }
  }

  Future<void> _loadReadingProgressForCurrent(
    MediaItem item,
    int loadVersion,
  ) async {
    if (item.kind != MediaKind.pdf) {
      return;
    }

    try {
      final entry = await _readingProgressService.fetchProgressForItem(item);
      if (!_isCurrentLoad(loadVersion, item)) {
        return;
      }

      final progressTotalPages = entry?.totalPages;
      final effectiveTotalPages =
          progressTotalPages != null && progressTotalPages > 0
          ? progressTotalPages
          : _totalPages;
      final nextPage = entry != null && !_hasMovedPdfPageSinceLoad
          ? entry.currentPage
          : _page;

      setState(() {
        _canPersistReadingProgress = true;
        if (effectiveTotalPages > 0) {
          _totalPages = effectiveTotalPages;
          _page = nextPage.clamp(1, _totalPages);
        } else {
          _page = nextPage < 1 ? 1 : nextPage;
        }
        _syncReaderFutures(item);
      });
      _schedulePersistCurrentActivity();
    } catch (_) {
      if (!_isCurrentLoad(loadVersion, item)) {
        return;
      }
      setState(() {
        _canPersistReadingProgress = true;
      });
      _schedulePersistCurrentActivity();
    }
  }

  Future<void> _reloadForCurrent() async {
    final item = _item;
    final loadVersion = ++_detailLoadVersion;

    _readerFutureCache.clear();
    _thumbFutureCache.clear();
    _loadedTagItemId = null;
    if (mounted) {
      final initialPage = item.kind == MediaKind.pdf
          ? (_pendingInitialPdfPage ?? 1)
          : 1;
      _pendingInitialPdfPage = null;
      setState(() {
        _canPersistReadingProgress = item.kind != MediaKind.pdf;
        _hasMovedPdfPageSinceLoad = false;
        _isFavorite = false;
        _tags = const [];
        _tagsLoading = false;
        if (_tagUsageScopeRaw != item.folderRaw) {
          _tagUsageCounts = <String, int>{};
        }
        _canDeleteFromLibrary =
            widget.repo.capabilities.canDelete && item.kind == MediaKind.pdf;
        _totalPages = 1;
        _page = initialPage < 1 ? 1 : initialPage;
        _syncReaderFutures(item);
      });
    }

    unawaited(_loadFavoriteForCurrent(loadVersion: loadVersion));
    if (item.kind == MediaKind.pdf) {
      unawaited(_loadReadingProgressForCurrent(item, loadVersion));
      unawaited(_loadPageCountForCurrent(item, loadVersion));
    }
    if (!_inReader) {
      _ensureDeferredDetailData();
    }
  }

  Widget _buildLoadError(String message, {required VoidCallback onRetry}) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.cloud_off_outlined,
              color: Colors.white70,
              size: 34,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('再試行'),
            ),
          ],
        ),
      ),
    );
  }

  void _next() {
    if (_isPdf) {
      final step = _twoPage ? 2 : 1;
      final next = _page + step;
      if (next <= _totalPages) {
        _setCurrentPdfPage(next);
      }
    } else {
      if (_index < _items.length - 1) {
        setState(() {
          _index++;
          _page = 1;
        });
        _pendingInitialPdfPage = 1;
        _reloadForCurrent();
      }
    }
  }

  void _prev() {
    if (_isPdf) {
      final step = _twoPage ? 2 : 1;
      final prev = _page - step;
      if (prev >= 1) {
        _setCurrentPdfPage(prev);
      }
    } else {
      if (_index > 0) {
        setState(() {
          _index--;
          _page = 1;
        });
        _pendingInitialPdfPage = 1;
        _reloadForCurrent();
      }
    }
  }

  KeyEventResult _handleReaderNavigationKeyEvent(
    FocusNode node,
    KeyEvent event,
  ) {
    if (_tab.index != 0 ||
        (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.gameButtonLeft1) {
      _prev();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.gameButtonRight1) {
      _next();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _renameCurrentItem() async {
    final item = _item;
    final newBase = await showRenameItemDialog(context, item: item);

    if (newBase == null || newBase.isEmpty) return;

    try {
      final updated = await widget.repo.rename(item, newBase);
      String? metadataWarning;
      try {
        await widget.tagService.handleItemRenamed(item, updated);
      } catch (e) {
        metadataWarning = 'メタデータの更新に失敗しました: $e';
      }
      final prefs = await SharedPreferences.getInstance();
      final favorites =
          (prefs.getStringList(_PrefsKeys.favorites) ?? const <String>[])
              .toSet();
      if (favorites.remove(item.id)) {
        favorites.add(updated.id);
        await prefs.setStringList(
          _PrefsKeys.favorites,
          favorites.toList(growable: false),
        );
      }
      if (!mounted) return;

      setState(() {
        _items[_index] = updated;
        _isFavorite = favorites.contains(updated.id);
      });
      _itemChanged = true;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('名前を変更しました: ${updated.displayName}')),
      );
      if (metadataWarning != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(metadataWarning)));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('名前の変更に失敗しました: $e')));
    }
  }

  void _schedulePersistCurrentActivity() {
    if (_isPdf && !_canPersistReadingProgress && !_hasMovedPdfPageSinceLoad) {
      return;
    }
    _activityPersistDebounce?.cancel();
    _activityPersistDebounce = Timer(
      const Duration(milliseconds: 350),
      () => unawaited(_persistCurrentActivity()),
    );
  }

  Future<void> _persistCurrentActivity({bool force = false}) async {
    final item = _item;
    if (item.kind != MediaKind.pdf) {
      return;
    }
    if (!force && !_canPersistReadingProgress && !_hasMovedPdfPageSinceLoad) {
      return;
    }
    final page = _page < 1 ? 1 : _page;
    final totalPages = _totalPages > 0 ? _totalPages : null;
    await _readingProgressService.saveProgressForItem(
      item,
      currentPage: page,
      totalPages: totalPages,
    );
  }

  Future<void> _toggleFullscreen() async {
    setState(() => _fullscreen = !_fullscreen);
    if (_fullscreen) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  // --- UI: responsive sidebar (Windows/desktop friendly) ---
  static const double _kSidebarWidth = 340;

  bool _isWideLayout(BuildContext context) =>
      MediaQuery.of(context).size.width >= 980;

  void _closeSidebar() {
    // Drawer陦ｨ遉ｺ譎ゅ・縺ｿ髢峨§繧具ｼ医ョ繧ｹ繧ｯ繝医ャ繝励・蟶ｸ險ｭ繧ｵ繧､繝峨ヰ繝ｼ縺ｧ縺ｯ pop 縺励↑縺・ｼ・
    if (!_isWideLayout(context)) {
      Navigator.pop(context);
    }
  }

  Future<void> _deleteCurrentItemWithWarning() async {
    if (!_canDeleteFromLibrary) return;

    final item = _item;

    final ok = await showControllerDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('この PDF を削除しますか？'),
        content: Text(
          '「${item.displayName}」を削除します。\n'
          '削除すると元に戻せません。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    // 螳溷炎髯､
    final bool deleted;
    try {
      deleted = await widget.repo.deleteItem(item);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('削除に失敗しました: $error')));
      return;
    }
    if (!mounted) return;

    if (!deleted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('削除に失敗しました')));
      return;
    }

    String? metadataWarning;
    try {
      await widget.tagService.handleDeletedItems([item]);
    } catch (e) {
      metadataWarning = 'メタデータ削除に失敗しました: $e';
    }

    // 縺頑ｰ励↓蜈･繧翫↓谿九▲縺ｦ繧九→繧ｴ繝溘↓縺ｪ繧九・縺ｧ螟悶☆
    final prefs = await SharedPreferences.getInstance();
    final fav = (prefs.getStringList(_PrefsKeys.favorites) ?? const <String>[])
        .toSet();
    fav.remove(item.id);
    await prefs.setStringList(
      _PrefsKeys.favorites,
      fav.toList(growable: false),
    );

    if (metadataWarning != null && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(metadataWarning)));
    }

    // 隧ｳ邏ｰ逕ｻ髱｢繧帝哩縺倥※荳隕ｧ蛛ｴ縺ｧ繝ｪ繝ｭ繝ｼ繝峨＆縺帙ｋ
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  Widget _withSidebar(BuildContext context, Widget body) {
    if (!_isWideLayout(context)) return body;
    return Row(
      children: [
        SizedBox(width: _kSidebarWidth, child: _buildSidebarPanel()),
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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: InputDecorator(
            decoration: const InputDecoration(
              labelText: '表示フィット',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<ReaderFitMode>(
                value: _fitMode,
                isDense: true,
                items: const [
                  DropdownMenuItem(
                    value: ReaderFitMode.vertical,
                    child: Text('縦フィット'),
                  ),
                  DropdownMenuItem(
                    value: ReaderFitMode.horizontal,
                    child: Text('横フィット'),
                  ),
                  DropdownMenuItem(
                    value: ReaderFitMode.contain,
                    child: Text('全体表示 (Contain)'),
                  ),
                ],
                onChanged: (v) async {
                  if (v == null) return;
                  setState(() => _fitMode = v);
                  await _saveFitMode(v);
                },
              ),
            ),
          ),
        ),
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

  @override
  Widget build(BuildContext context) {
    final wide = _isWideLayout(context);

    return ControllerNavigationRegion(
      debugLabel: 'detail-page',
      autofocusFirstFocusable: true,
      onKeyEvent: _handleReaderNavigationKeyEvent,
      child: WillPopScope(
        onWillPop: () async {
          _popWithResult();
          return false;
        },
        child: Scaffold(
          drawer: wide ? null : _buildSidebar(),
          backgroundColor: _uiBg,
          appBar: AppBar(
            backgroundColor: _uiBar,
            foregroundColor: Colors.white,

            title: Row(
              children: [
                Expanded(
                  child: Text(
                    _displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_inReader) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        reverse: true, // 蜿ｳ遶ｯ・域桃菴懷・・峨ｒ隕九○繧・☆縺上☆繧・
                        child: _topReaderControls(),
                      ),
                    ),
                  ),
                ],
              ],
            ),

            leadingWidth: wide ? 56 : 96,
            leading: Row(
              children: [
                IconButton(
                  tooltip: '戻る',
                  icon: const Icon(Icons.arrow_back),
                  onPressed: _popWithResult,
                ),
                if (!wide)
                  Builder(
                    builder: (ctx) => IconButton(
                      tooltip: 'メニュー',
                      icon: const Icon(Icons.menu),
                      onPressed: () => Scaffold.of(ctx).openDrawer(),
                    ),
                  ),
              ],
            ),

            actions: [
              IconButton(
                tooltip: _isFavorite ? 'お気に入りを解除' : 'お気に入りに追加',
                onPressed: _toggleFavorite,
                icon: Icon(_isFavorite ? Icons.star : Icons.star_border),
              ),
              IconButton(
                tooltip: _fullscreen ? 'フルスクリーン解除' : 'フルスクリーン',
                onPressed: _toggleFullscreen,
                icon: Icon(
                  _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                ),
              ),
              if (_canDeleteFromLibrary)
                PopupMenuButton<_DetailMenuAction>(
                  tooltip: 'メニュー',
                  onSelected: (a) {
                    if (a == _DetailMenuAction.delete) {
                      _deleteCurrentItemWithWarning();
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: _DetailMenuAction.delete,
                      child: ListTile(
                        leading: Icon(Icons.delete_outline),
                        title: Text('PDF を削除'),
                      ),
                    ),
                  ],
                ),
            ],
            bottom: TabBar(
              controller: _tab,
              tabs: const [
                Tab(text: '閲覧'),
                Tab(text: '詳細'),
              ],
            ),
          ),

          body: _withSidebar(
            context,
            Shortcuts(
              shortcuts: const <ShortcutActivator, Intent>{
                SingleActivator(LogicalKeyboardKey.pageUp): _PrevIntent(),
                SingleActivator(LogicalKeyboardKey.pageDown): _NextIntent(),
                SingleActivator(LogicalKeyboardKey.gameButtonLeft1):
                    _PrevIntent(),
                SingleActivator(LogicalKeyboardKey.gameButtonRight1):
                    _NextIntent(),
              },
              child: Actions(
                actions: <Type, Action<Intent>>{
                  _PrevIntent: CallbackAction<_PrevIntent>(
                    onInvoke: (intent) {
                      // 髢ｲ隕ｧ逕ｨ繧ｿ繝悶・縺ｨ縺阪□縺代・繝ｼ繧ｸ繧堤ｧｻ蜍・
                      if (_tab.index == 0) _prev();
                      return null;
                    },
                  ),
                  _NextIntent: CallbackAction<_NextIntent>(
                    onInvoke: (intent) {
                      if (_tab.index == 0) _next();
                      return null;
                    },
                  ),
                },
                child: Focus(
                  autofocus: true,
                  child: AnimatedBuilder(
                    animation: _tab,
                    builder: (context, _) {
                      if (_tab.index == 0) return _buildReader();
                      return _buildDetail();
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReader() {
    return Stack(
      children: [
        Center(
          child: LayoutBuilder(
            builder: (context, c) {
              const gap = 0.0;

              final isSpread = _twoPage && _isPdf;
              final pageW = isSpread ? (c.maxWidth - gap) / 2.0 : c.maxWidth;

              return Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: pageW,
                    child: _pageImage(
                      _leftFuture,
                      align: isSpread
                          ? Alignment.centerRight
                          : Alignment.center,
                      isSpread: isSpread,
                      pageNumber: _page,
                    ),
                  ),
                  if (isSpread) ...[
                    const SizedBox(width: gap),
                    SizedBox(
                      width: pageW,
                      child: _pageImage(
                        _rightFuture,
                        align: Alignment.centerLeft,
                        isSpread: isSpread,
                        pageNumber: _page + 1,
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),

        // 遶ｯ譛ｫ繧ｿ繝・・縺ｧ繝壹・繧ｸ驕ｷ遘ｻ・亥ｷｦ=蜑・/ 蜿ｳ=谺｡・・
        Positioned.fill(
          child: LayoutBuilder(
            builder: (context, c) {
              return GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTapUp: (details) {
                  // 髢ｲ隕ｧ逕ｨ繧ｿ繝紋ｻ･螟悶・辟｡隕悶☆繧・
                  if (_tab.index != 0) return;

                  final dx = details.localPosition.dx;
                  final w = c.maxWidth;

                  // 荳ｭ螟ｮ縺ｯ辟｡蜿榊ｿ懊↓
                  final leftEdge = w * 0.35;
                  final rightEdge = w * 0.65;

                  if (dx < leftEdge) {
                    _prev(); // 蟾ｦ繧ｿ繝・・ 竊・蜑・
                  } else if (dx > rightEdge) {
                    _next(); // 蜿ｳ繧ｿ繝・・ 竊・谺｡
                  }
                },
              );
            },
          ),
        ),
        if (_isPdf) _readerPageDropdownOverlay(),
      ],
    );
  }

  Widget _pageImage(
    Future<Uint8List>? future, {
    required Alignment align,
    required bool isSpread,
    required int pageNumber,
  }) {
    if (future == null) return const SizedBox.shrink();

    return FutureBuilder<Uint8List>(
      future: future,
      builder: (context, snap) {
        if (snap.hasError) {
          return _buildLoadError(
            '画像の読み込みに失敗しました。\n${snap.error}',
            onRetry: () {
              setState(() {
                _readerFutureCache.remove(pageNumber);
                _syncReaderFutures(_item);
              });
            },
          );
        }

        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        // 隕矩幕縺阪・縲檎ｸｦ蜷医ｏ縺帙搾ｼ九檎ｶｴ縺伜・蟇・○縲阪′荳逡ｪ螳牙ｮ壹＠繧・☆縺九▲縺・
        final fit = isSpread ? BoxFit.fitHeight : _boxFit;

        //pdf縺ｮ閭梧勹縺ｫ逋ｽ繧定ｿｽ蜉・磯乗・縺ｧ騾上￠縺ｦ隕九∴繧具ｼ・
        final img = Image.memory(
          snap.data!,
          fit: fit,
          alignment: align,
          gaplessPlayback: true,
          filterQuality: FilterQuality.high,
        );

        final widgetToShow = _isPdf
            ? DecoratedBox(
                decoration: const BoxDecoration(color: Colors.white),
                child: img,
              )
            : img;
        return InteractiveViewer(
          minScale: 0.5,
          maxScale: 6,
          alignment: align,
          child: Align(alignment: align, child: widgetToShow),
        );
      },
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
        _infoRow('種別', item.kind == MediaKind.pdf ? 'PDF' : '画像'),
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
                value: _selectedCategory,
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
                  setState(() => _selectedCategory = v);
                  await _loadMasterTags();
                },
              ),
            );

            final inputField = TextField(
              controller: _tagCtrl,
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
                backgroundColor: _uiChip,
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
              onPressed: () =>
                  _loadMasterTags(contains: _masterFilterCtrl.text),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 44,
          child: TextField(
            controller: _masterFilterCtrl,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: '候補を絞り込み（部分一致）',
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: (_masterFilterCtrl.text.trim().isEmpty)
                  ? null
                  : IconButton(
                      tooltip: 'クリア',
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _masterFilterCtrl.clear();
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

  List<TagWithId> get _masterTags =>
      _masterTagsByCategory[_selectedCategory] ?? const <TagWithId>[];

  Future<void> _addExistingMasterTag(TagWithId tag) {
    return _addSuggestedTag(tag.tag);
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
                label: item.kind == MediaKind.pdf ? 'PDF' : '画像',
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: _uiChip,
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

  Widget _buildAssignedTagsSection() {
    final grouped = _groupAssignedTags();
    final filteredCount = grouped.values.fold<int>(
      0,
      (sum, entries) => sum + entries.length,
    );

    return _buildTagSectionCard(
      title: '付与済みタグ',
      subtitle: filteredCount == _tags.length
          ? '${_tags.length}件'
          : '$filteredCount / ${_tags.length}件',
      trailing: TextButton.icon(
        onPressed: () {
          setState(() => _tagEditMode = !_tagEditMode);
        },
        icon: Icon(_tagEditMode ? Icons.check : Icons.edit_outlined),
        label: Text(_tagEditMode ? '編集を閉じる' : '編集する'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildTagSearchField(
            controller: _assignedFilterCtrl,
            hintText: '付与済みタグを探す',
            onChanged: (_) => setState(() {}),
          ),
          if (_tagEditMode) ...[
            const SizedBox(height: 12),
            _buildTagEditToolbar(),
          ],
          if (_tagsLoading) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
          const SizedBox(height: 12),
          if (filteredCount == 0 && !_tagsLoading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                _tags.isEmpty ? 'まだタグは付いていません。' : '検索条件に一致する付与済みタグはありません。',
                style: const TextStyle(color: Colors.white70),
              ),
            )
          else
            Column(
              children: [
                for (final category in _orderedTagCategories)
                  if ((grouped[category] ?? const <TagWithId>[]).isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _buildAssignedCategorySection(
                        category: category,
                        tags: grouped[category]!,
                      ),
                    ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildTagEditToolbar() {
    final categoryField = DropdownButtonFormField<TagCategory>(
      initialValue: _selectedCategory,
      decoration: const InputDecoration(
        labelText: '追加カテゴリ',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      items: _orderedTagCategories
          .map(
            (category) => DropdownMenuItem<TagCategory>(
              value: category,
              child: Text(_categoryLongLabel(category)),
            ),
          )
          .toList(growable: false),
      onChanged: (value) {
        if (value == null) {
          return;
        }
        setState(() => _selectedCategory = value);
      },
    );
    final inputField = TextField(
      controller: _tagCtrl,
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

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 720;
        final layoutToggle = Wrap(
          spacing: 8,
          children: [
            ChoiceChip(
              label: const Text('チップ'),
              selected: _tagLayoutMode == _TagLayoutMode.chips,
              onSelected: (_) {
                setState(() => _tagLayoutMode = _TagLayoutMode.chips);
              },
            ),
            ChoiceChip(
              label: const Text('リスト'),
              selected: _tagLayoutMode == _TagLayoutMode.list,
              onSelected: (_) {
                setState(() => _tagLayoutMode = _TagLayoutMode.list);
              },
            ),
          ],
        );

        if (narrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              categoryField,
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(child: inputField),
                  const SizedBox(width: 8),
                  addButton,
                ],
              ),
              const SizedBox(height: 10),
              layoutToggle,
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 190, child: categoryField),
            const SizedBox(width: 10),
            Expanded(child: inputField),
            const SizedBox(width: 10),
            addButton,
            const SizedBox(width: 12),
            Flexible(child: layoutToggle),
          ],
        );
      },
    );
  }

  Widget _buildAssignedCategorySection({
    required TagCategory category,
    required List<TagWithId> tags,
  }) {
    final key = 'assigned:${category.name}';
    final expanded = _isGroupExpanded(key, defaultValue: true);
    return _buildCategorySectionShell(
      category: category,
      count: tags.length,
      expanded: expanded,
      onToggle: () => _toggleGroupExpanded(key, defaultValue: true),
      child: _tagLayoutMode == _TagLayoutMode.list
          ? Column(
              children: [
                for (final entry in tags)
                  _buildAssignedListTile(
                    entry,
                    showDivider: entry != tags.last,
                  ),
              ],
            )
          : Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [for (final entry in tags) _buildAssignedChip(entry)],
            ),
    );
  }

  Widget _buildAssignedChip(TagWithId entry) {
    return InputChip(
      label: Text(
        '#${entry.tag.name}',
        style: const TextStyle(color: Colors.white),
      ),
      avatar: Icon(
        _categoryIcon(entry.tag.category),
        size: 16,
        color: _categoryColor(entry.tag.category),
      ),
      backgroundColor: _uiChip,
      deleteIconColor: Colors.white70,
      onDeleted: _tagEditMode ? () => _removeTagFromUi(entry) : null,
    );
  }

  Widget _buildAssignedListTile(TagWithId entry, {required bool showDivider}) {
    final usageCount = _tagUsageCount(entry.tag);
    final tile = ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        radius: 15,
        backgroundColor: _categoryColor(
          entry.tag.category,
        ).withValues(alpha: 0.18),
        child: Icon(
          _categoryIcon(entry.tag.category),
          size: 16,
          color: _categoryColor(entry.tag.category),
        ),
      ),
      title: Text(
        '#${entry.tag.name}',
        style: const TextStyle(color: Colors.white),
      ),
      subtitle: Text(
        usageCount > 0
            ? '${_categoryLongLabel(entry.tag.category)} · $usageCount件'
            : _categoryLongLabel(entry.tag.category),
        style: const TextStyle(color: Colors.white70),
      ),
      trailing: _tagEditMode
          ? IconButton(
              tooltip: '削除',
              icon: const Icon(Icons.close),
              onPressed: () => _removeTagFromUi(entry),
            )
          : null,
    );
    if (!showDivider) {
      return tile;
    }
    return Column(
      children: [
        tile,
        Divider(color: Colors.white.withValues(alpha: 0.08), height: 1),
      ],
    );
  }

  Widget _buildCandidateTagsSection() {
    final recommendedCount = _buildSuggestionEntries(
      _TagSuggestionTab.recommended,
    ).length;
    final recentCount = _buildSuggestionEntries(
      _TagSuggestionTab.recent,
    ).length;
    final allCount = _buildSuggestionEntries(_TagSuggestionTab.all).length;

    return _buildTagSectionCard(
      title: '候補タグ',
      subtitle: _masterLoading ? '読み込み中...' : '$allCount件',
      trailing: Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (_tagUsageLoading)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          IconButton(
            tooltip: '候補を更新',
            onPressed: () => _loadMasterTags(
              contains: _masterFilterCtrl.text.trim().isEmpty
                  ? null
                  : _masterFilterCtrl.text.trim(),
            ),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      child: SizedBox(
        height: _isWideLayout(context) ? 420 : 360,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildTagSearchField(
              controller: _masterFilterCtrl,
              hintText: '候補タグを探す',
              onChanged: (value) {
                setState(() {});
                _scheduleMasterTagReload(value);
              },
            ),
            const SizedBox(height: 12),
            TabBar(
              controller: _candidateTabController,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                Tab(text: 'おすすめ $recommendedCount'),
                Tab(text: '最近使った $recentCount'),
                Tab(text: 'すべて $allCount'),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: TabBarView(
                controller: _candidateTabController,
                children: [
                  _buildSuggestionTabBody(_TagSuggestionTab.recommended),
                  _buildSuggestionTabBody(_TagSuggestionTab.recent),
                  _buildSuggestionTabBody(_TagSuggestionTab.all),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSuggestionTabBody(_TagSuggestionTab tab) {
    final grouped = _groupSuggestionEntries(tab);
    final totalCount = grouped.values.fold<int>(
      0,
      (sum, entries) => sum + entries.length,
    );
    final scrollController = _candidateScrollControllers[tab]!;

    if (totalCount == 0) {
      return Center(
        child: Text(
          _masterLoading ? '候補を読み込み中です...' : '表示できる候補タグはありません。',
          style: const TextStyle(color: Colors.white70),
        ),
      );
    }

    return Scrollbar(
      controller: scrollController,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: scrollController,
        padding: const EdgeInsets.only(right: 8),
        child: Column(
          children: [
            for (final category in _orderedTagCategories)
              if ((grouped[category] ?? const <_TagSuggestionEntry>[])
                  .isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _buildSuggestionCategorySection(
                    tab: tab,
                    category: category,
                    entries: grouped[category]!,
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _buildSuggestionCategorySection({
    required _TagSuggestionTab tab,
    required TagCategory category,
    required List<_TagSuggestionEntry> entries,
  }) {
    final sectionKey = 'candidate:${tab.name}:${category.name}';
    final expanded = _isGroupExpanded(
      sectionKey,
      defaultValue:
          category == TagCategory.artist ||
          category == TagCategory.free ||
          entries.length <= 8,
    );
    final visibleCount = _visibleCandidateCount(tab, category, entries.length);
    final visibleEntries = entries.take(visibleCount).toList(growable: false);

    return _buildCategorySectionShell(
      category: category,
      count: entries.length,
      expanded: expanded,
      onToggle: () => _toggleGroupExpanded(
        sectionKey,
        defaultValue:
            category == TagCategory.artist ||
            category == TagCategory.free ||
            entries.length <= 8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_tagLayoutMode == _TagLayoutMode.list)
            Column(
              children: [
                for (final entry in visibleEntries)
                  _buildSuggestionListTile(
                    entry,
                    showDivider: entry != visibleEntries.last,
                  ),
              ],
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final entry in visibleEntries) _buildSuggestionChip(entry),
              ],
            ),
          if (entries.length > visibleEntries.length) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _showMoreCandidates(tab, category),
                icon: const Icon(Icons.expand_more),
                label: Text(
                  'もっと見る (${entries.length - visibleEntries.length}件)',
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSuggestionChip(_TagSuggestionEntry entry) {
    final usageCount = entry.usageCount;
    return ActionChip(
      avatar: Icon(
        entry.isRecent ? Icons.history : Icons.add_circle_outline,
        size: 16,
        color: _categoryColor(entry.tag.category),
      ),
      label: Text(
        usageCount > 0
            ? '#${entry.tag.name} · $usageCount'
            : '#${entry.tag.name}',
      ),
      onPressed: () => _addSuggestedTag(entry.tag),
    );
  }

  Widget _buildSuggestionListTile(
    _TagSuggestionEntry entry, {
    required bool showDivider,
  }) {
    final subtitleParts = <String>[
      _categoryLongLabel(entry.tag.category),
      if (entry.usageCount > 0) '${entry.usageCount}件',
      if (entry.isRecent) '最近使った',
    ];
    final tile = ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        radius: 15,
        backgroundColor: _categoryColor(
          entry.tag.category,
        ).withValues(alpha: 0.18),
        child: Icon(
          _categoryIcon(entry.tag.category),
          size: 16,
          color: _categoryColor(entry.tag.category),
        ),
      ),
      title: Text(
        '#${entry.tag.name}',
        style: const TextStyle(color: Colors.white),
      ),
      subtitle: Text(
        subtitleParts.join(' · '),
        style: const TextStyle(color: Colors.white70),
      ),
      trailing: FilledButton.tonalIcon(
        onPressed: () => _addSuggestedTag(entry.tag),
        icon: const Icon(Icons.add),
        label: const Text('追加'),
      ),
    );
    if (!showDivider) {
      return tile;
    }
    return Column(
      children: [
        tile,
        Divider(color: Colors.white.withValues(alpha: 0.08), height: 1),
      ],
    );
  }

  Widget _buildTagSearchField({
    required TextEditingController controller,
    required String hintText,
    required ValueChanged<String> onChanged,
  }) {
    return SizedBox(
      height: 44,
      child: SceneSearchField(
        controller: controller,
        hintText: hintText,
        onChanged: onChanged,
        onClear: () {
          controller.clear();
          onChanged('');
        },
      ),
    );
  }

  Widget _buildTagSectionCard({
    required String title,
    required String subtitle,
    required Widget child,
    Widget? trailing,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: Colors.white70),
                    ),
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 12), trailing],
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }

  Widget _buildCategorySectionShell({
    required TagCategory category,
    required int count,
    required bool expanded,
    required VoidCallback onToggle,
    required Widget child,
  }) {
    final color = _categoryColor(category);
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.02),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(
                children: [
                  Icon(_categoryIcon(category), color: color, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    _categoryLongLabel(category),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '$count',
                      style: TextStyle(
                        color: color,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    color: Colors.white70,
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: child,
            ),
        ],
      ),
    );
  }

  Widget _readerPageDropdownOverlay() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 12,
      child: SafeArea(
        minimum: const EdgeInsets.symmetric(horizontal: 12),
        child: Center(child: _pdfPageDropdown()),
      ),
    );
  }

  Widget _pdfPageDropdown() {
    final totalPages = _totalPages < 1 ? 1 : _totalPages;
    final currentPage = _page.clamp(1, totalPages).toInt();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: _uiChip,
        borderRadius: BorderRadius.circular(999),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: currentPage,
          isDense: true,
          menuMaxHeight: 360,
          dropdownColor: _uiBar,
          borderRadius: BorderRadius.circular(14),
          iconEnabledColor: Colors.white,
          style: const TextStyle(color: Colors.white, fontSize: 12),
          selectedItemBuilder: (context) => [
            for (var page = 1; page <= totalPages; page++)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'ページ $page',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
          ],
          items: [
            for (var page = 1; page <= totalPages; page++)
              DropdownMenuItem<int>(value: page, child: Text('ページ $page')),
          ],
          onChanged: totalPages <= 1
              ? null
              : (value) {
                  if (value == null || value == _page) {
                    return;
                  }
                  _setCurrentPdfPage(value);
                },
        ),
      ),
    );
  }

  Widget _topReaderControls() {
    final canPrev = _isPdf ? (_page > 1) : (_index > 0);
    final canNext = _isPdf
        ? (_page + (_twoPage ? 2 : 1) <= _totalPages)
        : (_index < _items.length - 1);

    final pageText = _isPdf
        ? '$_page/$_totalPages'
        : '${_index + 1}/${_items.length}';

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: '前',
          onPressed: canPrev ? _prev : null,
          icon: const Icon(Icons.chevron_left),
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        ),
        IconButton(
          tooltip: '谺｡',
          onPressed: canNext ? _next : null,
          icon: const Icon(Icons.chevron_right),
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          margin: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: _uiChip,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            pageText,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),

        // 隕矩幕縺阪・PDF縺縺・
        if (_isPdf)
          TextButton.icon(
            style: TextButton.styleFrom(
              foregroundColor: Colors.white,
              backgroundColor: _uiChip,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              visualDensity: VisualDensity.compact,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            icon: const Icon(Icons.swap_horiz, size: 18),
            label: Text(
              _twoPage ? '見開き ON' : '見開き OFF',
              style: const TextStyle(fontSize: 12),
            ),
            onPressed: () async {
              await _setTwoPageMode(!_twoPage);
            },
          ),

        const SizedBox(width: 6),

        // Fit ・亥・菴薙ｒ陦ｨ遉ｺ縺吶ｋ繝｢繝ｼ繝会ｼ・
        if (_isPdf)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            decoration: BoxDecoration(
              color: _uiChip,
              borderRadius: BorderRadius.circular(999),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                value: _page.clamp(1, _totalPages).toInt(),
                isDense: true,
                menuMaxHeight: 360,
                dropdownColor: _uiBar,
                borderRadius: BorderRadius.circular(14),
                iconEnabledColor: Colors.white,
                style: const TextStyle(color: Colors.white, fontSize: 12),
                selectedItemBuilder: (context) => [
                  for (var page = 1; page <= _totalPages; page++)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'ページ $page',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
                items: [
                  for (var page = 1; page <= _totalPages; page++)
                    DropdownMenuItem<int>(
                      value: page,
                      child: Text('ページ $page'),
                    ),
                ],
                onChanged: _totalPages <= 1
                    ? null
                    : (value) {
                        if (value == null || value == _page) {
                          return;
                        }
                        _setCurrentPdfPage(value);
                      },
              ),
            ),
          ),

        if (_isPdf) const SizedBox(width: 6),

        PopupMenuButton<ReaderFitMode>(
          tooltip: 'Fit',
          initialValue: _fitMode,
          onSelected: (v) async {
            setState(() => _fitMode = v);
            await _saveFitMode(v);
          },
          itemBuilder: (context) => const [
            PopupMenuItem(value: ReaderFitMode.vertical, child: Text('縦フィット')),
            PopupMenuItem(
              value: ReaderFitMode.horizontal,
              child: Text('横フィット'),
            ),
            PopupMenuItem(
              value: ReaderFitMode.contain,
              child: Text('全体表示 (Contain)'),
            ),
          ],
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: _uiChip,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.aspect_ratio, size: 18, color: Colors.white),
                const SizedBox(width: 6),
                Text(switch (_fitMode) {
                  ReaderFitMode.vertical => '縦',
                  ReaderFitMode.horizontal => '横',
                  ReaderFitMode.contain => '全体',
                }, style: const TextStyle(color: Colors.white, fontSize: 12)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPdfThumbGrid(MediaItem item) {
    final total = _totalPages;

    return SliverGrid(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 0.75,
      ),
      delegate: SliverChildBuilderDelegate((context, i) {
        final page = i + 1;

        return ControllerFocusable(
          debugLabel: 'detail-thumb-$page',
          borderRadius: BorderRadius.circular(10),
          onPressed: () {
            _setCurrentPdfPage(page);
            _tab.animateTo(0);
          },
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: _uiChip,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: page == _page ? Colors.white : Colors.transparent,
                width: 2,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: FutureBuilder<Uint8List>(
                future: _loadThumbBytes(item, page),
                builder: (context, snap) {
                  if (snap.hasError) {
                    return _buildLoadError(
                      'ページ $page のサムネイル取得に失敗しました。',
                      onRetry: () {
                        setState(() {
                          _thumbFutureCache.remove(page);
                        });
                      },
                    );
                  }
                  if (!snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  return Image.memory(
                    snap.data!,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.low,
                  );
                },
              ),
            ),
          ),
        );
      }, childCount: total),
    );
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

class _PrevIntent extends Intent {
  const _PrevIntent();
}

class _NextIntent extends Intent {
  const _NextIntent();
}
