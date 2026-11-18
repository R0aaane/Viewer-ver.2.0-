import 'package:flutter/material.dart';

class ReadingResumeCard extends StatelessWidget {
  const ReadingResumeCard({
    super.key,
    required this.title,
    required this.preview,
    required this.progress,
    required this.pageLabel,
    required this.description,
    required this.onResume,
  });
  final String title;
  final Widget preview;
  final double progress;
  final String pageLabel;
  final String description;
  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final theme = Theme.of(context);
          final cover = ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(width: 120, height: 156, child: preview),
          );
          final details = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '続きから読む',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                description,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              Semantics(
                label: '読書の進捗',
                value: '${(progress.clamp(0, 1) * 100).round()}%',
                child: LinearProgressIndicator(
                  value: progress.clamp(0, 1),
                  minHeight: 4,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: onResume,
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text('$pageLabel から再開'),
              ),
            ],
          );
          if (constraints.maxWidth < 480 ||
              MediaQuery.textScalerOf(context).scale(1) > 1.5) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [cover, const SizedBox(height: 16), details],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              cover,
              const SizedBox(width: 24),
              Expanded(child: details),
            ],
          );
        },
      ),
    ),
  );
}
