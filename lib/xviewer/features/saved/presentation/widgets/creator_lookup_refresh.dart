// ignore_for_file: deprecated_member_use

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../domain/models/creator_search_target.dart';
import '../../../../domain/models/saved_media_record.dart';
import '../../../../services/service_providers.dart';
import '../providers/saved_media_controller.dart';

Future<void> refreshCreatorLookups({
  required BuildContext context,
  required WidgetRef ref,
  required List<SavedMediaRecord> records,
}) async {
  final latestByAuthor = <String, SavedMediaRecord>{};
  for (final record in records) {
    final existing = latestByAuthor[record.authorUsername];
    if (existing == null || record.savedAt.isAfter(existing.savedAt)) {
      latestByAuthor[record.authorUsername] = record;
    }
  }

  final authors = latestByAuthor.values.toList(growable: false);
  if (authors.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('No visible creators to search')),
    );
    return;
  }

  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(
    SnackBar(content: Text('Searching ${authors.length} creators...')),
  );

  final resolver = ref.read(creatorSiteResolverServiceProvider);
  final results = <_CreatorLookupRefreshResult>[];
  for (final record in authors) {
    final matches = await resolver.resolve(
      authorName: record.authorName,
      authorUsername: record.authorUsername,
      allowNetwork: true,
      refresh: true,
    );
    results.add(
      _CreatorLookupRefreshResult(
        record: record,
        matches: matches,
      ),
    );
  }

  if (!context.mounted) {
    return;
  }

  messenger.hideCurrentSnackBar();
  final selectedNames = await _showCreatorLookupResults(
    context: context,
    results: results,
  );
  if (selectedNames == null || selectedNames.isEmpty) {
    return;
  }

  final controller = ref.read(savedMediaControllerProvider.notifier);
  for (final entry in selectedNames.entries) {
    await controller.applyAuthorDisplayName(
      authorUsername: entry.key,
      displayName: entry.value,
    );
  }
}

Future<Map<String, String>?> _showCreatorLookupResults({
  required BuildContext context,
  required List<_CreatorLookupRefreshResult> results,
}) {
  final selectedNames = <String, String>{};
  for (final result in results) {
    final names = result.matchTitles;
    if (names.length > 1) {
      selectedNames[result.record.authorUsername] = names.first;
    }
  }

  return showDialog<Map<String, String>>(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          final foundCount = results
              .where((result) => result.matches.isNotEmpty)
              .length;
          return AlertDialog(
            title: const Text('Creator search results'),
            content: SizedBox(
              width: 520,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 520),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: results.length,
                  separatorBuilder: (context, index) =>
                      const Divider(height: 24),
                  itemBuilder: (context, index) {
                    final result = results[index];
                    return _CreatorLookupResultTile(
                      result: result,
                      selectedName: selectedNames[result.record.authorUsername],
                      onSelectName: (value) {
                        setDialogState(() {
                          selectedNames[result.record.authorUsername] = value;
                        });
                      },
                    );
                  },
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
              FilledButton(
                onPressed: selectedNames.isEmpty
                    ? null
                    : () => Navigator.of(context).pop(selectedNames),
                child: Text(
                  selectedNames.isEmpty
                      ? '$foundCount found'
                      : 'Save selected names',
                ),
              ),
            ],
          );
        },
      );
    },
  );
}

class _CreatorLookupResultTile extends StatelessWidget {
  const _CreatorLookupResultTile({
    required this.result,
    required this.selectedName,
    required this.onSelectName,
  });

  final _CreatorLookupRefreshResult result;
  final String? selectedName;
  final ValueChanged<String> onSelectName;

  @override
  Widget build(BuildContext context) {
    final record = result.record;
    final names = result.matchTitles;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          record.authorName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall,
        ),
        Text(
          '@${record.authorUsername}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        if (result.matches.isEmpty)
          const Text('No matches found')
        else ...[
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: result.matches.map((match) {
              return Chip(
                avatar: _TargetFavicon(target: match.target),
                label: Text('${match.target.label}: ${match.title}'),
              );
            }).toList(growable: false),
          ),
          if (names.length > 1) ...[
            const SizedBox(height: 8),
            ...names.map((name) {
              return RadioListTile<String>(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: name,
                groupValue: selectedName,
                onChanged: (value) {
                  if (value != null) {
                    onSelectName(value);
                  }
                },
                title: Text(name),
              );
            }),
          ],
        ],
      ],
    );
  }
}

class _TargetFavicon extends StatelessWidget {
  const _TargetFavicon({required this.target});

  final CreatorSearchTarget target;

  @override
  Widget build(BuildContext context) {
    final assetPath = target.faviconAssetPath;
    if (assetPath != null) {
      return Image.asset(
        assetPath,
        width: 16,
        height: 16,
        errorBuilder: (context, error, stackTrace) =>
            Icon(target.icon, size: 16),
      );
    }
    return Image.network(
      target.faviconUrl,
      width: 16,
      height: 16,
      errorBuilder: (context, error, stackTrace) =>
          Icon(target.icon, size: 16),
    );
  }
}

class _CreatorLookupRefreshResult {
  const _CreatorLookupRefreshResult({
    required this.record,
    required this.matches,
  });

  final SavedMediaRecord record;
  final List<CreatorSearchMatch> matches;

  List<String> get matchTitles {
    return matches
        .map((match) => match.title.trim())
        .where((title) => title.isNotEmpty)
        .toSet()
        .toList(growable: false);
  }
}
