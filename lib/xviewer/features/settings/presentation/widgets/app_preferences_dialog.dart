import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_preferences_controller.dart';

class AppPreferencesDialog extends ConsumerStatefulWidget {
  const AppPreferencesDialog({super.key});

  @override
  ConsumerState<AppPreferencesDialog> createState() =>
      _AppPreferencesDialogState();
}

class _AppPreferencesDialogState extends ConsumerState<AppPreferencesDialog> {
  late final TextEditingController _savedItemsLabelController;

  @override
  void initState() {
    super.initState();
    final preferences = ref.read(appPreferencesProvider);
    _savedItemsLabelController = TextEditingController(
      text: preferences.savedItemsLabel,
    );
  }

  @override
  void dispose() {
    _savedItemsLabelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final preferences = ref.watch(appPreferencesProvider);

    if (_savedItemsLabelController.text != preferences.savedItemsLabel) {
      _savedItemsLabelController.value = TextEditingValue(
        text: preferences.savedItemsLabel,
        selection: TextSelection.collapsed(
          offset: preferences.savedItemsLabel.length,
        ),
      );
    }

    return AlertDialog(
      title: const Text('Display settings'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Background color',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 12),
            SegmentedButton<AppBackgroundMode>(
              segments: const [
                ButtonSegment<AppBackgroundMode>(
                  value: AppBackgroundMode.white,
                  label: Text('White'),
                  icon: Icon(Icons.light_mode_outlined),
                ),
                ButtonSegment<AppBackgroundMode>(
                  value: AppBackgroundMode.black,
                  label: Text('Black'),
                  icon: Icon(Icons.dark_mode_outlined),
                ),
              ],
              selected: {preferences.backgroundMode},
              onSelectionChanged: (selection) {
                ref
                    .read(appPreferencesProvider.notifier)
                    .setBackgroundMode(selection.first);
              },
            ),
            const SizedBox(height: 20),
            Text(
              'Saved label',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _savedItemsLabelController,
              decoration: const InputDecoration(
                hintText: 'Saved Images',
                helperText: 'This name is used in the saved screen title.',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await ref.read(appPreferencesProvider.notifier).reset();
          },
          child: const Text('Reset'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton(
          onPressed: () async {
            await ref
                .read(appPreferencesProvider.notifier)
                .setSavedItemsLabel(_savedItemsLabelController.text);
            if (context.mounted) {
              Navigator.of(context).pop();
            }
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
