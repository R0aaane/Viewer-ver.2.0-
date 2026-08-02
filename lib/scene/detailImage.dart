import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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
import '../services/epub_text_extractor.dart';
import '../widgets/controller_focusable.dart';
import 'widgets/scene_ui.dart';
import 'rename_item_dialog.dart';
import 'TagResults.dart';

part 'image_detail_page.dart';
part 'reader_view.dart';
part 'detail_reader_controller.dart';
part 'detail_tag_controller.dart';
part 'detail_tag_panel.dart';
part 'detail_actions.dart';
part 'detail_widgets.dart';

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
  _ReadingDirection _readingDirection = _ReadingDirection.rightToLeft;
  bool _fullscreen = false;
  bool _inReader = true;
  bool _leaving = false;

  bool _isFavorite = false;
  bool _isBookmarked = false;
  bool _favChanged = false;
  int? _rating;
  bool _ratingChanged = false;
  bool _itemChanged = false;
  bool _sidebarCollapsed = false;

  // tag・医ち繧ｰ・・
  List<TagWithId> _tags = const [];
  List<MediaItem> _relatedItems = const [];
  bool _relatedItemsLoading = false;
  String? _relatedItemsForItemId;
  bool _tagsChanged = false;
  bool _tagEditMode = false;
  _TagLayoutMode _tagLayoutMode = _TagLayoutMode.chips;
  late final DetailTagController _tagController;

  //縲繝輔か繝ｫ繝繧・ヵ繧｡繧､繝ｫ繧貞炎髯､
  bool _canDeleteFromLibrary = false;

  // 蛟呵｣徼ag縺ｮ繧ｭ繝｣繝・す繝･
  Map<TagCategory, List<TagWithId>> _masterTagsByCategory =
      <TagCategory, List<TagWithId>>{};
  bool _masterLoading = false;
  Timer? _activityPersistDebounce;
  int? _pendingInitialPdfPage;
  bool _canPersistReadingProgress = true;
  bool _hasMovedPdfPageSinceLoad = false;

  bool _tagsLoading = false;
  String? _loadedTagItemId;
  String? _kemonoVerticalBaseId;
  bool _kemonoVerticalLoading = false;
  List<MediaItem>? _kemonoVerticalItems;
  bool _masterTagsInitialized = false;
  int _detailLoadVersion = 0;
  bool _recentTagsLoaded = false;
  List<Tag> _recentTags = const <Tag>[];
  bool _tagUsageLoading = false;
  String? _tagUsageScopeRaw;
  Map<String, int> _tagUsageCounts = <String, int>{};

  ReaderFitMode _fitMode = ReaderFitMode.vertical;

  late final DetailReaderController _readerController;
  Future<EpubTextDocument>? _epubDocumentFuture;
  String? _epubDocumentItemId;

  MediaItem get _item => _items[_index];
  bool get _isPdf => _item.kind == MediaKind.pdf;
  bool get _isEpub => _item.kind == MediaKind.epub;
  bool get _canRenameCurrentItem => widget.repo.capabilities.canRename;
  String get _displayTitle =>
      ItemNameService.formatMediaTitle(_item.displayName, kind: _item.kind);

  static const _uiBg = Color(0xFF0F0F10);
  static const _uiBar = Color(0xFF1F1F1F);
  static const _uiChip = Color(0xFF2B2B2B);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _items = widget.items;
    _index = widget.initialIndex;
    _page = widget.initialPdfPage ?? 1;
    _pendingInitialPdfPage = widget.initialPdfPage;
    _readerController = DetailReaderController(
      repo: widget.repo,
      initialIndex: widget.initialIndex,
      initialPreloadItemId: widget.initialPreloadItemId,
      initialPageCountFuture: widget.initialPageCountFuture,
      initialReaderBytesFuture: widget.initialReaderBytesFuture,
    );
    _tagController = DetailTagController();

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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _activityPersistDebounce?.cancel();
    _tagController.dispose();
    unawaited(_persistCurrentActivity());
    for (final controller in _candidateScrollControllers.values) {
      controller.dispose();
    }
    _candidateTabController.dispose();
    _tab.dispose();
    _disposeEpubController();
    if (_fullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  void _disposeEpubController() {
    _epubDocumentFuture = null;
    _epubDocumentItemId = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_persistCurrentActivity(force: true));
    }
  }

  bool _isCurrentLoad(int loadVersion, MediaItem item) {
    return mounted && loadVersion == _detailLoadVersion && _item.id == item.id;
  }

  void _ensureDeferredDetailData() {
    if (_loadedTagItemId != _item.id && !_tagsLoading) {
      unawaited(_loadTagsForCurrent());
    }
    if (_loadedTagItemId == _item.id &&
        _relatedItemsForItemId != _item.id &&
        !_relatedItemsLoading) {
      unawaited(_loadRelatedItemsForCurrent(_tags, _detailLoadVersion));
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

  // ----------------
  // Tags (SharedPreferences萓晏ｭ・

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
        key == LogicalKeyboardKey.gameButtonLeft1) {
      if (_isPdf) {
        _readingDirection == _ReadingDirection.rightToLeft ? _next() : _prev();
      } else {
        _prev();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageUp) {
      _prev();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.gameButtonRight1) {
      if (_isPdf) {
        _readingDirection == _ReadingDirection.rightToLeft ? _prev() : _next();
      } else {
        _next();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageDown) {
      _next();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // --- UI: responsive sidebar (Windows/desktop friendly) ---
  static const double _kSidebarWidth = 340;

  @override
  Widget build(BuildContext context) {
    final wide = _isWideLayout(context);

    return ControllerNavigationRegion(
      debugLabel: 'detail-page',
      autofocusFirstFocusable: true,
      onKeyEvent: _handleReaderNavigationKeyEvent,
      child: WillPopScope(
        onWillPop: () async {
          if (_fullscreen) {
            await _setFullscreen(false);
            return false;
          }
          await _popWithResult();
          return false;
        },
        child: Scaffold(
          drawer: wide || _fullscreen ? null : _buildSidebar(),
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
                if (_inReader || _fullscreen) ...[
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
                  onPressed: () => _fullscreen
                      ? unawaited(_setFullscreen(false))
                      : unawaited(_popWithResult()),
                ),
                if (!wide && !_fullscreen)
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
              if (wide && !_fullscreen) _buildSidebarToggleButton(),
              IconButton(
                tooltip: _isFavorite ? 'お気に入りを解除' : 'お気に入りに追加',
                onPressed: _toggleFavorite,
                icon: Icon(_isFavorite ? Icons.star : Icons.star_border),
              ),
              if (_isPdf)
                IconButton(
                  tooltip: _isBookmarked ? 'しおりを外す' : 'しおりを挟む',
                  onPressed: _toggleBookmark,
                  icon: Icon(
                    _isBookmarked ? Icons.bookmark : Icons.bookmark_border,
                  ),
                ),
              IconButton(
                tooltip: _fullscreen ? 'フルスクリーン解除' : 'フルスクリーン',
                onPressed: _toggleFullscreen,
                icon: Icon(
                  _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                ),
              ),
              if (!_fullscreen && _canDeleteFromLibrary)
                PopupMenuButton<_DetailMenuAction>(
                  tooltip: 'メニュー',
                  onSelected: (a) {
                    if (a == _DetailMenuAction.delete) {
                      _deleteCurrentItemWithWarning();
                    } else if (a == _DetailMenuAction.deletePdfPage) {
                      _deleteCurrentPdfPageWithWarning();
                    }
                  },
                  itemBuilder: (context) => [
                    if (_isPdf && widget.repo.capabilities.canEditPdfPages)
                      const PopupMenuItem(
                        value: _DetailMenuAction.deletePdfPage,
                        child: ListTile(
                          leading: Icon(Icons.delete_sweep_outlined),
                          title: Text('現在のページを削除'),
                        ),
                      ),
                    const PopupMenuItem(
                      value: _DetailMenuAction.delete,
                      child: ListTile(
                        leading: Icon(Icons.delete_outline),
                        title: Text('PDF を削除'),
                      ),
                    ),
                  ],
                ),
            ],
            bottom: _fullscreen
                ? null
                : TabBar(
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
                SingleActivator(LogicalKeyboardKey.escape):
                    _ExitFullscreenIntent(),
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
                  _ExitFullscreenIntent: CallbackAction<_ExitFullscreenIntent>(
                    onInvoke: (intent) {
                      if (_fullscreen) {
                        unawaited(_setFullscreen(false));
                      }
                      return null;
                    },
                  ),
                },
                child: Focus(
                  autofocus: true,
                  child: AnimatedBuilder(
                    animation: _tab,
                    builder: (context, _) {
                      if (_fullscreen || _tab.index == 0) return _buildReader();
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
}
