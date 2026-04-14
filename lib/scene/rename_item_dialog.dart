import 'package:flutter/material.dart';

import '../models/mediaItem.dart';
import '../services/controller_navigation_service.dart';
import '../services/item_name_service.dart';

Future<String?> showRenameItemDialog(
  BuildContext context, {
  required MediaItem item,
}) {
  final controller = TextEditingController(
    text: ItemNameService.editableBaseName(item),
  );

  return showControllerDialog<String>(
    context: context,
    builder: (dialogContext) {
      String? errorText;

      return StatefulBuilder(
        builder: (context, setState) {
          void submit() {
            final value = controller.text;
            final error = ItemNameService.validateEditableName(value.trim());
            if (error != null) {
              setState(() => errorText = error);
              return;
            }
            Navigator.of(dialogContext).pop(value.trim());
          }

          final helperText = switch (item.kind) {
            MediaKind.pdf => '拡張子 .pdf はそのまま保持されます',
            MediaKind.image => '拡張子はそのまま保持されます',
            MediaKind.folder => null,
          };

          return AlertDialog(
            title: const Text('名前変更'),
            content: TextField(
              controller: controller,
              autofocus: true,
              onChanged: (_) {
                if (errorText != null) {
                  setState(() => errorText = null);
                }
              },
              onSubmitted: (_) => submit(),
              decoration: InputDecoration(
                labelText: '新しい名前',
                helperText: helperText,
                errorText: errorText,
                border: const OutlineInputBorder(),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('キャンセル'),
              ),
              FilledButton(onPressed: submit, child: const Text('変更')),
            ],
          );
        },
      );
    },
  ).whenComplete(controller.dispose);
}
