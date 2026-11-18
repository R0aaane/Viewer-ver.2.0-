import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../repository/generated_media_repository.dart';

class GenerationComparisonPage extends StatefulWidget {
  final GeneratedMediaRepository repo;
  final Map<String, String> images;
  final VoidCallback? viewImages;

  const GenerationComparisonPage({
    super.key,
    required this.repo,
    required this.images,
    this.viewImages,
  });

  @override
  State<GenerationComparisonPage> createState() => _GenerationComparisonPageState();
}

class _GenerationComparisonPageState extends State<GenerationComparisonPage> {
  late final selected = widget.images.keys.take(2).toList();
  late final imageIds = widget.images.keys.toList();

  void toggle(String id) {
    setState(() {
      if (selected.remove(id)) return;
      if (selected.length == 2) selected.removeAt(0);
      selected.add(id);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('生成結果を比較'),
        actions: [
          if (widget.viewImages != null)
            IconButton(
              tooltip: 'ホストの生成画像',
              icon: const Icon(Icons.photo_library_outlined),
              onPressed: widget.viewImages,
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: selected.isEmpty
                  ? const Center(child: Text('下の候補から画像を選んでください'))
                  : Row(
                      children: [
                        for (final id in selected)
                          Expanded(
                            key: ValueKey(id),
                            child: Column(
                              children: [
                                Padding(
                                  padding: const EdgeInsets.all(8),
                                  child: Text(widget.images[id]!),
                                ),
                                Expanded(
                                  child: InteractiveViewer(
                                    maxScale: 8,
                                    child: SizedBox.expand(
                                      child: Image.network(
                                        widget.repo.originalUrl(id),
                                        headers: widget.repo.headers,
                                        fit: BoxFit.contain,
                                        errorBuilder: (_, _, _) => const Center(
                                          child: Text('画像を表示できません'),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
            ),
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text('候補を選択（最大2枚）'),
            ),
            SizedBox(
              height: 96,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: imageIds.length,
                itemBuilder: (context, index) {
                  final id = imageIds[index];
                  return Padding(
                    padding: const EdgeInsets.all(4),
                    child: FilterChip(
                      labelPadding: EdgeInsets.zero,
                      tooltip: widget.images[id],
                      label: SizedBox(
                        width: 64,
                        height: 64,
                        child: GenerationThumbnail(repo: widget.repo, id: id),
                      ),
                      selected: selected.contains(id),
                      onSelected: (_) => toggle(id),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class GenerationThumbnail extends StatelessWidget {
  final GeneratedMediaRepository repo;
  final String id;

  const GenerationThumbnail({super.key, required this.repo, required this.id});

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: repo.thumbnail(id),
    builder: (context, snapshot) => snapshot.hasData
        ? ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(
              snapshot.data!,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
            ),
          )
        : Icon(
            snapshot.hasError
                ? Icons.image_not_supported_outlined
                : Icons.image_outlined,
          ),
  );
}
