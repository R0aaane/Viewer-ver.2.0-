import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../domain/models/creator_search_target.dart';
import '../../../../services/service_providers.dart';

Future<void> showCreatorSearchSheet({
  required BuildContext context,
  required WidgetRef ref,
  required String authorName,
  required String authorUsername,
}) async {
  final trimmedName = authorName.trim();
  final trimmedUsername = authorUsername.trim();
  final query = trimmedName.isNotEmpty ? trimmedName : trimmedUsername;
  if (query.isEmpty) {
    return;
  }

  final messenger = ScaffoldMessenger.of(context);
  final target = await showModalBottomSheet<CreatorSearchTarget>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
              child: Row(
                children: [
                  const Icon(Icons.manage_search_rounded),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          query,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(sheetContext).textTheme.titleMedium,
                        ),
                        if (trimmedUsername.isNotEmpty)
                          Text(
                            '@$trimmedUsername',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(sheetContext).textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: query));
                      Navigator.of(sheetContext).pop();
                      messenger.showSnackBar(
                        const SnackBar(content: Text('Creator name copied')),
                      );
                    },
                    icon: const Icon(Icons.content_copy_rounded),
                    tooltip: 'Copy creator name',
                  ),
                ],
              ),
            ),
            ...CreatorSearchTarget.values.map((target) {
              return ListTile(
                leading: _SearchTargetFavicon(target: target),
                title: Text(target.label),
                subtitle: Text(target.description),
                trailing: const Icon(Icons.open_in_new_rounded),
                onTap: () => Navigator.of(sheetContext).pop(target),
              );
            }),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );

  if (target == null || !context.mounted) {
    return;
  }

  final uri = target.buildUri(query);
  try {
    await ref.read(linkLauncherServiceProvider).openExternal(
          uri.toString(),
          debugLabel: '${target.label} creator search',
          failureMessage: 'Could not open creator search',
        );
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }
}

class _SearchTargetFavicon extends StatelessWidget {
  const _SearchTargetFavicon({required this.target});

  final CreatorSearchTarget target;

  @override
  Widget build(BuildContext context) {
    final assetPath = target.faviconAssetPath;
    return SizedBox.square(
      dimension: 24,
      child: assetPath == null
          ? Image.network(
              target.faviconUrl,
              width: 20,
              height: 20,
              errorBuilder: (context, error, stackTrace) {
                return Icon(target.icon, size: 22);
              },
            )
          : Image.asset(
              assetPath,
              width: 20,
              height: 20,
              errorBuilder: (context, error, stackTrace) {
                return Icon(target.icon, size: 22);
              },
            ),
    );
  }
}
