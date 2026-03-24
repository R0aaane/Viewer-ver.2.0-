import 'package:flutter/material.dart';

import '../database/tag_service.dart';
import '../models/tag.dart' as model;
import '../repository/mediaRepository.dart';
import 'TagResults.dart';
import 'widgets/scene_ui.dart';

class ArtistTagIndexPage extends StatefulWidget {
  final TagService tagService;
  final MediaRepository repo;

  const ArtistTagIndexPage({
    super.key,
    required this.tagService,
    required this.repo,
  });

  @override
  State<ArtistTagIndexPage> createState() => _ArtistTagIndexPageState();
}

class _ArtistTagIndexPageState extends State<ArtistTagIndexPage> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _openTag(String name) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TagResultsPage(
          tagService: widget.tagService,
          repo: widget.repo,
          category: model.TagCategory.artist,
          tagName: name,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('アーティストタグ'),
        actions: [
          IconButton(
            tooltip: '更新',
            onPressed: () => setState(() {}),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: SceneSearchField(
              controller: _search,
              hintText: 'タグ名で検索',
              onChanged: (value) => setState(() => _query = value.trim()),
              onClear: () {
                _search.clear();
                setState(() => _query = '');
              },
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: FutureBuilder<List<model.Tag>>(
              future: widget.tagService.listTagsByCategory(
                model.TagCategory.artist,
              ),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final tags = snapshot.data!
                    .map((tag) => tag.name.trim())
                    .where((name) => name.isNotEmpty)
                    .toSet()
                    .toList(growable: false);

                final filtered = _query.isEmpty
                    ? tags
                    : tags
                        .where(
                          (name) =>
                              name.toLowerCase().contains(_query.toLowerCase()),
                        )
                        .toList(growable: false);

                final grouped = <String, List<String>>{};
                for (final name in filtered) {
                  final key = _groupKey(name);
                  (grouped[key] ??= <String>[]).add(name);
                }

                for (final entry in grouped.entries) {
                  entry.value.sort(
                    (left, right) =>
                        left.toLowerCase().compareTo(right.toLowerCase()),
                  );
                }

                final keys = grouped.keys.toList(growable: false)
                  ..sort((left, right) => _groupOrder(left).compareTo(
                        _groupOrder(right),
                      ));

                if (keys.isEmpty) {
                  return const SceneEmptyState(
                    icon: Icons.search_off,
                    title: '一致するタグがありません',
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                  itemCount: keys.length,
                  itemBuilder: (context, index) {
                    final key = keys[index];
                    return _GroupSection(
                      title: key,
                      items: grouped[key]!,
                      onTap: _openTag,
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  String _groupKey(String name) {
    final value = name.trim();
    if (value.isEmpty) return '#';

    final first = String.fromCharCode(value.runes.first);
    final upper = first.toUpperCase();
    if (upper.codeUnitAt(0) >= 65 && upper.codeUnitAt(0) <= 90) {
      return upper;
    }

    final hiragana = _toHiragana(first);
    return _kanaHead(hiragana) ?? '#';
  }

  int _groupOrder(String key) {
    if (key.length == 1) {
      final code = key.codeUnitAt(0);
      if (code >= 65 && code <= 90) {
        return code - 65;
      }
    }

    const kanaOrder = <String, int>{
      'あ': 1000,
      'か': 1001,
      'さ': 1002,
      'た': 1003,
      'な': 1004,
      'は': 1005,
      'ま': 1006,
      'や': 1007,
      'ら': 1008,
      'わ': 1009,
    };
    return kanaOrder[key] ?? 9999;
  }

  String _toHiragana(String value) {
    if (value.isEmpty) return value;
    final code = value.codeUnitAt(0);
    if (code >= 0x30A1 && code <= 0x30F6) {
      return String.fromCharCode(code - 0x60);
    }
    return value;
  }

  String? _kanaHead(String hiragana) {
    if (hiragana.isEmpty) return null;

    const groups = <String, String>{
      'ぁ': 'あ',
      'あ': 'あ',
      'ぃ': 'あ',
      'い': 'あ',
      'ぅ': 'あ',
      'う': 'あ',
      'ぇ': 'あ',
      'え': 'あ',
      'ぉ': 'あ',
      'お': 'あ',
      'か': 'か',
      'が': 'か',
      'き': 'か',
      'ぎ': 'か',
      'く': 'か',
      'ぐ': 'か',
      'け': 'か',
      'げ': 'か',
      'こ': 'か',
      'ご': 'か',
      'さ': 'さ',
      'ざ': 'さ',
      'し': 'さ',
      'じ': 'さ',
      'す': 'さ',
      'ず': 'さ',
      'せ': 'さ',
      'ぜ': 'さ',
      'そ': 'さ',
      'ぞ': 'さ',
      'た': 'た',
      'だ': 'た',
      'ち': 'た',
      'ぢ': 'た',
      'っ': 'た',
      'つ': 'た',
      'づ': 'た',
      'て': 'た',
      'で': 'た',
      'と': 'た',
      'ど': 'た',
      'な': 'な',
      'に': 'な',
      'ぬ': 'な',
      'ね': 'な',
      'の': 'な',
      'は': 'は',
      'ば': 'は',
      'ぱ': 'は',
      'ひ': 'は',
      'び': 'は',
      'ぴ': 'は',
      'ふ': 'は',
      'ぶ': 'は',
      'ぷ': 'は',
      'へ': 'は',
      'べ': 'は',
      'ぺ': 'は',
      'ほ': 'は',
      'ぼ': 'は',
      'ぽ': 'は',
      'ま': 'ま',
      'み': 'ま',
      'む': 'ま',
      'め': 'ま',
      'も': 'ま',
      'ゃ': 'や',
      'や': 'や',
      'ゅ': 'や',
      'ゆ': 'や',
      'ょ': 'や',
      'よ': 'や',
      'ら': 'ら',
      'り': 'ら',
      'る': 'ら',
      'れ': 'ら',
      'ろ': 'ら',
      'ゎ': 'わ',
      'わ': 'わ',
      'を': 'わ',
      'ん': 'わ',
    };

    return groups[hiragana];
  }
}

class _GroupSection extends StatelessWidget {
  final String title;
  final List<String> items;
  final ValueChanged<String> onTap;

  const _GroupSection({
    required this.title,
    required this.items,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ExpansionTile(
        initiallyExpanded: title == 'あ' || title == 'A',
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        childrenPadding: const EdgeInsets.only(bottom: 8),
        title: Text('$title (${items.length})'),
        children: [
          for (final name in items)
            ListTile(
              title: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => onTap(name),
            ),
        ],
      ),
    );
  }
}
