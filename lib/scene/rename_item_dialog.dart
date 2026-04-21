import 'package:flutter/material.dart';

import '../models/mediaItem.dart';
import '../services/item_name_service.dart';

Future<String?> showRenameItemDialog(
  BuildContext context, {
  required MediaItem item,
}) {
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => _RenameItemDialog(item: item),
  );
}

class _RenameItemDialog extends StatefulWidget {
  final MediaItem item;

  const _RenameItemDialog({required this.item});

  @override
  State<_RenameItemDialog> createState() => _RenameItemDialogState();
}

class _RenameItemDialogState extends State<_RenameItemDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: ItemNameService.editableBaseName(widget.item),
  );
  String? _errorText;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    final error = ItemNameService.validateEditableName(value);
    if (error != null) {
      setState(() => _errorText = error);
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final helperText = switch (widget.item.kind) {
      MediaKind.pdf => '拡張子 .pdf はそのまま維持されます。',
      MediaKind.image => '拡張子はそのまま維持されます。',
      MediaKind.folder => null,
    };

    return AlertDialog(
      title: const Text('名前を変更'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        onChanged: (_) {
          if (_errorText != null) {
            setState(() => _errorText = null);
          }
        },
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          labelText: '新しい名前',
          helperText: helperText,
          errorText: _errorText,
          border: const OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('変更'),
        ),
      ],
    );
  }
}
