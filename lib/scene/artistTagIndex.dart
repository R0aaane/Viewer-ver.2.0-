import 'package:flutter/material.dart';
import '../database/tag_service.dart';
import '../models/tag.dart' as model;

import '../repository/mediaRepository.dart';
import 'TagResults.dart';

class ArtistTagIndexPage extends StatefulWidget {
  final TagService tagService;
  final MediaRepository repo;
  const ArtistTagIndexPage({
    super.key, 
    required this.tagService,
    required this.repo
    });

  @override
  State<ArtistTagIndexPage> createState() => _ArtistTagIndexPageState();
}

class _ArtistTagIndexPageState extends State<ArtistTagIndexPage> {
  final TextEditingController _search = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
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
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: TextField(
              controller: _search,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '検索（例: a / さ / #部分一致）',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _q = v.trim()),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: FutureBuilder<List<model.Tag>>(
              future: widget.tagService.listTagsByCategory(model.TagCategory.artist),
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final tags = snap.data!
                    .map((t) => t.name)
                    .where((name) => name.trim().isNotEmpty)
                    .toList(growable: false);

                // 検索（部分一致）
                final filtered = (_q.isEmpty)
                    ? tags
                    : tags.where((x) => x.toLowerCase().contains(_q.toLowerCase())).toList();

                // グルーピング（A-Z / あ-ん / その他）
                final grouped = <String, List<String>>{};
                for (final name in filtered) {
                  final key = _groupKey(name);
                  (grouped[key] ??= <String>[]).add(name);
                }

                // 各グループ内は自然ソートっぽく（単純比較）
                for (final k in grouped.keys) {
                  grouped[k]!.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
                }

                final keys = grouped.keys.toList()
                  ..sort((a, b) => _groupOrder(a).compareTo(_groupOrder(b)));

                if (keys.isEmpty) {
                  return const Center(child: Text('タグがありません'));
                }

                return ListView.builder(
                  itemCount: keys.length,
                  itemBuilder: (context, i) {
                    final key = keys[i];
                    final list = grouped[key]!;
                    return _GroupSection(
                      title: key,
                      items: list,
                      onTap: (name) {
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
                      },
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

  // ---------- group key: A-Z / あ-ん ----------
  String _groupKey(String name) {
    final s = name.trim();
    if (s.isEmpty) return '#';

    final first = s.runes.first;
    final ch = String.fromCharCode(first);

    // Latin
    final upper = ch.toUpperCase();
    if (upper.codeUnitAt(0) >= 65 && upper.codeUnitAt(0) <= 90) {
      return upper;
    }

    // Japanese (hiragana/katakana)
    final hira = _toHiragana(ch);
    final g = _kanaHead(hira);
    if (g != null) return g;

    return '#';
  }

  // ソート順: A-Z -> あ〜ん -> #（その他）
  int _groupOrder(String key) {
    if (key.length == 1) {
      final c = key.codeUnitAt(0);
      if (c >= 65 && c <= 90) return 0 * 1000 + (c - 65);
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
      'ん': 1010,
    };
    final v = kanaOrder[key];
    if (v != null) return v;
    return 9999;
  }

  // katakana -> hiragana（単一文字のみ想定）
  String _toHiragana(String ch) {
    if (ch.isEmpty) return ch;
    final code = ch.codeUnitAt(0);
    // Katakana block: 0x30A1..0x30F6
    if (code >= 0x30A1 && code <= 0x30F6) {
      return String.fromCharCode(code - 0x60);
    }
    return ch;
  }

  // 先頭かなを五十音の「行」に丸める（が→か / ぱ→は など）
  String? _kanaHead(String hira) {
    if (hira.isEmpty) return null;
    final code = hira.codeUnitAt(0);

    // Hiragana block: 0x3041..0x3096
    if (code < 0x3041 || code > 0x3096) return null;

    // 濁点/半濁点/小書きも吸収
    const map = <String, String>{
      // あ行
      'ぁ':'あ','あ':'あ','ぃ':'あ','い':'あ','ぅ':'あ','う':'あ','ぇ':'あ','え':'あ','ぉ':'あ','お':'あ',
      // か行
      'か':'か','き':'か','く':'か','け':'か','こ':'か',
      'が':'か','ぎ':'か','ぐ':'か','げ':'か','ご':'か',
      // さ行
      'さ':'さ','し':'さ','す':'さ','せ':'さ','そ':'さ',
      'ざ':'さ','じ':'さ','ず':'さ','ぜ':'さ','ぞ':'さ',
      // た行
      'た':'た','ち':'た','つ':'た','て':'た','と':'た',
      'だ':'た','ぢ':'た','づ':'た','で':'た','ど':'た',
      // な行
      'な':'な','に':'な','ぬ':'な','ね':'な','の':'な',
      // は行
      'は':'は','ひ':'は','ふ':'は','へ':'は','ほ':'は',
      'ば':'は','び':'は','ぶ':'は','べ':'は','ぼ':'は',
      'ぱ':'は','ぴ':'は','ぷ':'は','ぺ':'は','ぽ':'は',
      // ま行
      'ま':'ま','み':'ま','む':'ま','め':'ま','も':'ま',
      // や行
      'ゃ':'や','や':'や','ゅ':'や','ゆ':'や','ょ':'や','よ':'や',
      // ら行
      'ら':'ら','り':'ら','る':'ら','れ':'ら','ろ':'ら',
      // わ行
      'ゎ':'わ','わ':'わ','を':'わ',
      // ん
      'ん':'ん',
    };

    final head = map[hira];
    return head;
  }
}

class _GroupSection extends StatelessWidget {
  final String title;
  final List<String> items;
  final void Function(String) onTap;

  const _GroupSection({
    required this.title,
    required this.items,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      initiallyExpanded: title == 'あ' || title == 'A',
      title: Text('$title (${items.length})'),
      children: [
        for (final name in items)
          ListTile(
            title: Text(name),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => onTap(name),
          ),
      ],
    );
  }
}