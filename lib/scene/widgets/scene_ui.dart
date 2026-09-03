import 'package:flutter/material.dart';

/// Shared desktop spacing and sizing tokens for the library screens.
abstract final class SceneSpace {
  static const double x1 = 4;
  static const double x2 = 8;
  static const double x3 = 12;
  static const double x4 = 16;
  static const double x6 = 24;
  static const double x8 = 32;
  static const double sidebarWidth = 232;
  static const double inspectorWidth = 304;
}

class SceneSectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  const SceneSectionHeader({
    super.key,
    required this.title,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(0, 0, 0, SceneSpace.x2),
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(child: Text(title, style: textTheme.titleMedium)),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class SceneSurfaceCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  const SceneSurfaceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(SceneSpace.x3),
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(padding: padding, child: child),
    );
  }
}

class SceneSearchField extends StatelessWidget {
  final TextEditingController? controller;
  final String hintText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onClear;
  final bool enabled;

  const SceneSearchField({
    super.key,
    this.controller,
    required this.hintText,
    this.onChanged,
    this.onSubmitted,
    this.onClear,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final hasText = controller?.text.trim().isNotEmpty ?? false;
    return TextField(
      controller: controller,
      enabled: enabled,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search, size: 20),
        hintText: hintText,
        border: const OutlineInputBorder(),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: SceneSpace.x2),
        suffixIconConstraints: const BoxConstraints(minWidth: 0),
        suffixIcon: hasText
            ? IconButton(
                tooltip: 'クリア',
                onPressed: onClear,
                icon: const Icon(Icons.clear),
              )
            : null,
      ),
    );
  }
}

class SceneEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;

  const SceneEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 42, color: colorScheme.primary),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (message != null) ...[
                const SizedBox(height: 8),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class SceneSidebarHeader extends StatelessWidget {
  final String title;
  final String? subtitle;

  const SceneSidebarHeader({super.key, required this.title, this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SceneSpace.x4,
        SceneSpace.x4,
        SceneSpace.x4,
        SceneSpace.x3,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          if (subtitle != null && subtitle!.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

class SceneSidebarSectionLabel extends StatelessWidget {
  final String text;

  const SceneSidebarSectionLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SceneSpace.x4,
        SceneSpace.x6,
        SceneSpace.x4,
        SceneSpace.x2,
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
