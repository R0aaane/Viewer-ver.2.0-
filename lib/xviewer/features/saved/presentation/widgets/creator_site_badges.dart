import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../domain/models/creator_search_target.dart';
import '../../../../domain/models/saved_media_record.dart';
import '../../../../services/service_providers.dart';
import '../providers/saved_media_controller.dart';

class CreatorSiteBadges extends ConsumerStatefulWidget {
  const CreatorSiteBadges({
    super.key,
    required this.record,
    this.compact = false,
    this.allowNetworkLookup = false,
  });

  final SavedMediaRecord record;
  final bool compact;
  final bool allowNetworkLookup;

  @override
  ConsumerState<CreatorSiteBadges> createState() => _CreatorSiteBadgesState();
}

class _CreatorSiteBadgesState extends ConsumerState<CreatorSiteBadges> {
  late Future<_CreatorSiteBadgeState> _stateFuture;

  @override
  void initState() {
    super.initState();
    _stateFuture = _loadState();
  }

  @override
  void didUpdateWidget(CreatorSiteBadges oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.record.authorUsername != widget.record.authorUsername ||
        oldWidget.record.authorName != widget.record.authorName ||
        oldWidget.allowNetworkLookup != widget.allowNetworkLookup) {
      _stateFuture = _loadState();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_CreatorSiteBadgeState>(
      future: _stateFuture,
      builder: (context, snapshot) {
        final data = snapshot.data;
        final matches = data?.matches ?? const <CreatorSearchMatch>[];
        final needsDisplayName = data?.needsDisplayName ??
            _needsDisplayName(
              widget.record.authorName,
              widget.record.authorUsername,
            );
        if (matches.isEmpty && !needsDisplayName) {
          return const SizedBox.shrink();
        }

        return Padding(
          padding: EdgeInsets.only(top: widget.compact ? 4 : 6),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ...matches.map((match) {
                return _CreatorSiteBadge(
                  match: match,
                  compact: widget.compact,
                );
              }),
              if (needsDisplayName)
                _DisplayNameLookupBadge(
                  record: widget.record,
                  compact: widget.compact,
                ),
            ],
          ),
        );
      },
    );
  }

  Future<_CreatorSiteBadgeState> _loadState() async {
    final displayNameService = ref.read(creatorDisplayNameServiceProvider);
    final localName = await displayNameService.findLocalDisplayName(
      widget.record.authorUsername,
    );
    final effectiveAuthorName = (localName ?? widget.record.authorName).trim();
    final matches = await ref.read(creatorSiteResolverServiceProvider).resolve(
          authorName: effectiveAuthorName,
          authorUsername: widget.record.authorUsername,
          allowNetwork: widget.allowNetworkLookup,
        );

    return _CreatorSiteBadgeState(
      matches: matches,
      needsDisplayName: _needsDisplayName(
        effectiveAuthorName,
        widget.record.authorUsername,
      ),
    );
  }

  bool _needsDisplayName(String authorName, String authorUsername) {
    final name = authorName.trim();
    final username = authorUsername.trim();
    return name.isEmpty ||
        name == 'Unknown' ||
        name == 'unknown_user' ||
        _normalizeUsername(name) == _normalizeUsername(username);
  }

  String _normalizeUsername(String value) {
    return value.trim().replaceFirst(RegExp(r'^@+'), '').toLowerCase();
  }
}

class _CreatorSiteBadgeState {
  const _CreatorSiteBadgeState({
    required this.matches,
    required this.needsDisplayName,
  });

  final List<CreatorSearchMatch> matches;
  final bool needsDisplayName;
}

class _CreatorSiteBadge extends ConsumerWidget {
  const _CreatorSiteBadge({
    required this.match,
    required this.compact,
  });

  final CreatorSearchMatch match;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = _badgeColors(context, match.target);
    return Tooltip(
      message: 'Open ${match.target.label}: ${match.title}',
      child: Material(
        color: colors.$1,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: () => _open(context, ref),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 5 : 6,
              vertical: compact ? 4 : 5,
            ),
            child: _TargetFavicon(
              target: match.target,
              size: compact ? 14 : 16,
              fallbackColor: colors.$2,
            ),
          ),
        ),
      ),
    );
  }

  (Color, Color) _badgeColors(
    BuildContext context,
    CreatorSearchTarget target,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return switch (target) {
      CreatorSearchTarget.hitomi => (
          colorScheme.primaryContainer,
          colorScheme.onPrimaryContainer,
        ),
      CreatorSearchTarget.kemono => (
          colorScheme.tertiaryContainer,
          colorScheme.onTertiaryContainer,
        ),
      CreatorSearchTarget.dddSmart => (
          colorScheme.secondaryContainer,
          colorScheme.onSecondaryContainer,
        ),
      CreatorSearchTarget.crossSiteSearch => (
          colorScheme.surfaceContainerHighest,
          colorScheme.onSurface,
        ),
    };
  }

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(linkLauncherServiceProvider).openExternal(
            match.url,
            debugLabel: '${match.target.label} creator page',
            failureMessage: 'Could not open creator page',
          );
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }
}

class _TargetFavicon extends StatelessWidget {
  const _TargetFavicon({
    required this.target,
    required this.size,
    required this.fallbackColor,
  });

  final CreatorSearchTarget target;
  final double size;
  final Color fallbackColor;

  @override
  Widget build(BuildContext context) {
    final assetPath = target.faviconAssetPath;
    if (assetPath != null) {
      return Image.asset(
        assetPath,
        width: size,
        height: size,
        errorBuilder: (context, error, stackTrace) => _fallback(context),
      );
    }

    return Image.network(
      target.faviconUrl,
      width: size,
      height: size,
      errorBuilder: (context, error, stackTrace) => _fallback(context),
    );
  }

  Widget _fallback(BuildContext context) {
    return Text(
      target.mark,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: fallbackColor,
            fontWeight: FontWeight.w700,
          ),
    );
  }
}

class _DisplayNameLookupBadge extends ConsumerWidget {
  const _DisplayNameLookupBadge({
    required this.record,
    required this.compact,
  });

  final SavedMediaRecord record;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'Find X display name',
      child: Material(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: () => _lookup(context, ref),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 5 : 6,
              vertical: compact ? 4 : 5,
            ),
            child: Icon(
              Icons.manage_search_rounded,
              size: compact ? 14 : 16,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _lookup(BuildContext context, WidgetRef ref) async {
    final selected = await _showDisplayNameDialog(
      context: context,
      authorUsername: record.authorUsername,
      onOpenSearch: () => _openDisplayNameSearch(context, ref),
    );
    if (selected == null || selected.trim().isEmpty) {
      return;
    }

    await ref.read(savedMediaControllerProvider.notifier).applyAuthorDisplayName(
          authorUsername: record.authorUsername,
          displayName: selected,
        );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved display name: $selected')),
      );
    }
  }

  Future<String?> _showDisplayNameDialog({
    required BuildContext context,
    required String authorUsername,
    required Future<void> Function() onOpenSearch,
  }) async {
    final controller = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: Text('@$authorUsername'),
            content: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      'Open a web search, then enter the display name to save it locally.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                  TextField(
                    controller: controller,
                    decoration: const InputDecoration(
                      labelText: 'Display name',
                    ),
                    onSubmitted: (value) => Navigator.of(context).pop(value),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton.icon(
                onPressed: onOpenSearch,
                icon: const Icon(Icons.open_in_new_rounded),
                label: const Text('Search web'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(controller.text),
                child: const Text('Save'),
              ),
            ],
          );
        },
      );
    } finally {
      controller.dispose();
    }
  }

  Future<void> _openDisplayNameSearch(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final username = record.authorUsername.trim().replaceFirst(
          RegExp(r'^@+'),
          '',
        );
    if (username.isEmpty) {
      return;
    }

    final uri = Uri.https(
      'duckduckgo.com',
      '/',
      {'q': 'site:x.com/$username @$username X'},
    );
    try {
      await ref.read(linkLauncherServiceProvider).openExternal(
            uri.toString(),
            debugLabel: 'display name search',
            failureMessage: 'Could not open display name search',
          );
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }
}
