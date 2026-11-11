import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import '../../services/local_ai_bridge.dart';

class LocalAiPanel extends StatefulWidget {
  final LocalAiBridge bridge;
  const LocalAiPanel({super.key, required this.bridge});
  @override
  State<LocalAiPanel> createState() => _LocalAiPanelState();
}

class _LocalAiPanelState extends State<LocalAiPanel> {
  bool _busy = false;
  String? _error;
  Future<void> _select() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final files = await openFiles(
        acceptedTypeGroups: [
          const XTypeGroup(label: 'PDF資料', extensions: ['pdf']),
        ],
      );
      if (files.isNotEmpty && mounted) {
        await widget.bridge.start(
          files.map((f) => LocalAiDocument(f.path, f.name)).toList(),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = '連携を開始できません。別のビューアーで連携していないか確認してください。');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.bridge,
    builder: (context, _) => Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  'LocalAI連携${widget.bridge.connected ? '：${widget.bridge.documentCount}件を共有中' : ''}',
                ),
                TextButton(
                  onPressed: _busy ? null : _select,
                  child: const Text('LocalAIに共有するPDFを選ぶ'),
                ),
                if (widget.bridge.connected)
                  TextButton(
                    onPressed: _busy ? null : widget.bridge.stop,
                    child: const Text('連携を解除'),
                  ),
              ],
            ),
            const Text(
              '一般向け資料を選択後、LocalAIに「資料「名前」を開いて」または「資料「キーワード」のおすすめをホームに表示」と送信。共有は今回の起動中だけ有効です。',
            ),
            if (_error != null) Text(_error!),
            if (widget.bridge.recommendations.isNotEmpty) ...[
              Text('LocalAIのおすすめ — ${widget.bridge.reason}'),
              Wrap(
                spacing: 8,
                children: widget.bridge.recommendations
                    .map(
                      (d) => ActionChip(
                        label: Text(d.title),
                        onPressed: () async {
                          await widget.bridge.open(d);
                        },
                      ),
                    )
                    .toList(),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
