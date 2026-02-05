import 'dart:typed_data';
import 'package:flutter/material.dart';

import '../models/folder.dart';
import '../models/mediaItem.dart';
import '../repository/mediaRepository.dart';
import 'detailImage.dart';

/// 作品単位の表示エントリ
/// - PDF: pages = [pdfItem]
/// - 画像: pages = [folder内の画像item...]
class WorkEntry {
  final String title; // グリッド下に表示するタイトル（フォルダ名など）
  final List<MediaItem> pages; // 作品の“ページ”として扱うMediaItem群（並び順が重要）

  WorkEntry({required this.title, required this.pages});

  MediaItem get coverItem => pages.first;
  bool get isPdf => pages.length == 1 && pages.first.kind == MediaKind.pdf;
}

class GalleryGridPage extends StatefulWidget {
  final MediaRepository repo;
  const GalleryGridPage({super.key, required this.repo});

  @override
  State<GalleryGridPage> createState() => _GalleryGridPageState();
}

class _GalleryGridPageState extends State<GalleryGridPage> {
  FolderHandle? _folder;
  List<WorkEntry> _works = const [];
  bool _loading = false;

  // --- 検索状態
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickFolderAndLoad() async {
    final folder = await widget.repo.pickFolder();
    if (folder == null) return;

    setState(() {
      _folder = folder;
      _loading = true;
      _works = const [];
      _query = '';
      _searchCtrl.text = '';
    });

    final items = await widget.repo.listMedia(folder);
    if (!mounted) return;

    final works = _buildWorks(items);

    setState(() {
      _works = works;
      _loading = false;
    });
  }

  /// フラット一覧を「作品単位」にまとめる
  List<WorkEntry> _buildWorks(List<MediaItem> items) {
    final pdfs = <MediaItem>[];
    final images = <MediaItem>[];

    for (final it in items) {
      if (it.kind == MediaKind.pdf) {
        pdfs.add(it);
      } else {
        images.add(it);
      }
    }

    // 画像を「親フォルダキー」でグルーピング
    final Map<String, List<MediaItem>> byDir = {};
    for (final img in images) {
      final key = _parentDirKey(img);
      (byDir[key] ??= <MediaItem>[]).add(img);
    }

    // ページ順を安定化（ファイル名でソート）
    for (final entry in byDir.entries) {
      entry.value.sort((a, b) => a.displayName.compareTo(b.displayName));
    }

    final works = <WorkEntry>[];

    // PDF（個別作品）
    pdfs.sort((a, b) => a.displayName.compareTo(b.displayName));
    for (final pdf in pdfs) {
      works.add(WorkEntry(title: pdf.displayName, pages: [pdf]));
    }

    // 画像（フォルダ作品）
    final dirKeys = byDir.keys.toList()..sort();
    for (final dirKey in dirKeys) {
      final pages = byDir[dirKey]!;
      final title = _dirName(dirKey);
      works.add(WorkEntry(title: title, pages: pages));
    }

    return works;
  }

  /// ★重要：ここだけあなたの MediaItem 実装に合わせて直してください
  String _parentDirKey(MediaItem item) {
    // TODO: ★★ここを実際のMediaItemの「パス字段」に合わせて変更★★
    // 例: final String path = item.path; / item.filePath; / item.rawPath; / item.uri.toString();
    final String path = item.displayName; // ← 仮置き。必ず直してください。

    final normalized = path.replaceAll('\\', '/');
    final idx = normalized.lastIndexOf('/');
    if (idx <= 0) return '(root)';
    return normalized.substring(0, idx);
  }

  String _dirName(String dirKey) {
    final normalized = dirKey.replaceAll('\\', '/');
    final idx = normalized.lastIndexOf('/');
    if (idx < 0) return normalized;
    final tail = normalized.substring(idx + 1);
    return tail.isEmpty ? normalized : tail;
  }

  // ---------------------------
  // タブ種別
  // ---------------------------
  List<WorkEntry> _filterByTab(int tabIndex) {
    switch (tabIndex) {
      case 1:
        return _works.where((w) => w.isPdf).toList();
      case 2:
        return _works.where((w) => !w.isPdf).toList();
      default:
        return _works;
    }
  }

  // ---------------------------
  // 検索（タイトル部分一致・大小無視）
  // ---------------------------
  List<WorkEntry> _applySearch(List<WorkEntry> src) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return src;
    return src.where((w) => w.title.toLowerCase().contains(q)).toList();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3, // すべて / PDF / 画像
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            _folder == null ? '一覧表示' : '一覧表示: ${_folder!.raw}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            IconButton(
              tooltip: 'フォルダ選択',
              onPressed: _pickFolderAndLoad,
              icon: const Icon(Icons.folder_open),
            ),
          ],

          // ★ AppBar下に「タブ + 検索バー」を配置
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(96),
            child: Column(
              children: [
                const TabBar(
                  tabs: [
                    Tab(text: 'すべて'),
                    Tab(text: 'PDF'),
                    Tab(text: '画像'),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  child: TextField(
                    controller: _searchCtrl,
                    onChanged: (v) => setState(() => _query = v),
                    decoration: InputDecoration(
                      hintText: 'タイトルで検索（例: 作品名 / フォルダ名）',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: (_query.isEmpty)
                          ? null
                          : IconButton(
                              tooltip: 'クリア',
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                _searchCtrl.clear();
                                setState(() => _query = '');
                              },
                            ),
                      filled: true,
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        body: _folder == null
            ? Center(
                child: ElevatedButton(
                  onPressed: _pickFolderAndLoad,
                  child: const Text('フォルダ選択'),
                ),
              )
            : _loading
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                children: [
                  _buildGridForTab(0),
                  _buildGridForTab(1),
                  _buildGridForTab(2),
                ],
              ),
      ),
    );
  }

  Widget _buildGridForTab(int tabIndex) {
    final byTab = _filterByTab(tabIndex);
    final filtered = _applySearch(byTab);

    if (filtered.isEmpty) {
      return Center(
        child: Text(_query.trim().isEmpty ? 'データがありません' : '検索結果がありません'),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(10),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 0.72,
      ),
      itemCount: filtered.length,
      itemBuilder: (context, i) {
        final work = filtered[i];

        return InkWell(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ImageDetailPage(
                  repo: widget.repo,
                  items: work.pages, // PDFは1件、画像はフォルダ内の全画像
                  initialIndex: 0, // 表紙から
                  initialPdfPage: 1,
                ),
              ),
            );
          },
          child: _WorkThumbTile(repo: widget.repo, work: work),
        );
      },
    );
  }
}

/// 作品サムネ（PDFは既存readThumbPair、画像作品は1枚目/2枚目を重ねて表示）
class _WorkThumbTile extends StatelessWidget {
  final MediaRepository repo;
  final WorkEntry work;
  const _WorkThumbTile({required this.repo, required this.work});

  Future<ThumbPair> _loadThumbs() async {
    if (work.isPdf) {
      return repo.readThumbPair(work.coverItem, maxWidth: 360);
    }

    // 画像フォルダ作品：1枚目を表紙、2枚目があれば背後に
    final front = await repo
        .readThumbPair(work.pages[0], maxWidth: 360)
        .then((p) => p.front);
    Uint8List? back;
    if (work.pages.length >= 2) {
      back = await repo
          .readThumbPair(work.pages[1], maxWidth: 360)
          .then((p) => p.front);
    }
    return ThumbPair(front: front, back: back);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ThumbPair>(
      future: _loadThumbs(),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const _TileShell(loading: true);
        }
        if (!snap.hasData) {
          return const _TileShell(error: true);
        }

        final pair = snap.data!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _BookStack(front: pair.front, back: pair.back),
            ),
            const SizedBox(height: 6),
            Text(
              work.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        );
      },
    );
  }
}

class _BookStack extends StatelessWidget {
  final Uint8List front;
  final Uint8List? back;
  const _BookStack({required this.front, this.back});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        if (back != null)
          Positioned(
            left: 10,
            top: 6,
            right: 0,
            bottom: 0,
            child: _ThumbCard(bytes: back!, elevation: 2, dim: true),
          ),
        Positioned(
          left: 0,
          top: 0,
          right: 10,
          bottom: 6,
          child: _ThumbCard(bytes: front, elevation: 6),
        ),
      ],
    );
  }
}

class _ThumbCard extends StatelessWidget {
  final Uint8List bytes;
  final double elevation;
  final bool dim;
  const _ThumbCard({required this.bytes, this.elevation = 4, this.dim = false});

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: elevation,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: ColorFiltered(
        colorFilter: dim
            ? const ColorFilter.matrix(<double>[
                0.85,
                0,
                0,
                0,
                0,
                0,
                0.85,
                0,
                0,
                0,
                0,
                0,
                0.85,
                0,
                0,
                0,
                0,
                0,
                1,
                0,
              ])
            : const ColorFilter.mode(Colors.transparent, BlendMode.dst),
        child: Image.memory(
          bytes,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          filterQuality: FilterQuality.low,
        ),
      ),
    );
  }
}

class _TileShell extends StatelessWidget {
  final bool loading;
  final bool error;
  const _TileShell({this.loading = false, this.error = false});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Center(
        child: loading
            ? const CircularProgressIndicator(strokeWidth: 2)
            : const Icon(Icons.broken_image),
      ),
    );
  }
}
