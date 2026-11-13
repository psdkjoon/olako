import 'package:flutter/material.dart' hide Text, Icon;
import 'package:flutter/widgets.dart' as w show Text;
import 'package:olako/localization/localization.dart';
import 'package:olako/reader/document_loader.dart';
import 'package:olako/theme/app_spacing.dart';
import 'package:olako/ui/widgets/kind_info.dart';

class DocumentTile extends StatelessWidget {
  const DocumentTile({
    required this.kind,
    required this.title,
    required this.meta,
    required this.onTap,
    this.folder,
    this.progress = 0,
    this.pinned = false,
    this.onLongPress,
    super.key,
  });

  final DocumentKind kind;
  final String title;
  final String meta;
  final String? folder;
  final double progress;
  final bool pinned;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  static const double _badge = 52;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final place = folder;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
      child: Material(
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              spacing: AppSpacing.md,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(AppRadius.tile),
                  ),
                  child: SizedBox.square(
                    dimension: _badge,
                    child: Icon(
                      KindInfo.icon(kind),
                      size: 26,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: AppSpacing.xxs,
                    children: [
                      Row(
                        spacing: AppSpacing.xxs,
                        children: [
                          Expanded(
                            child: w.Text(
                              title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall,
                            ),
                          ),
                          if (pinned)
                            Icon(
                              Icons.push_pin_rounded,
                              size: 16,
                              color: scheme.primary,
                            ),
                        ],
                      ),
                      if (place != null)
                        w.Text(
                          place,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textDirection: TextDirection.ltr,
                          style: muted,
                        ),
                      w.Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: muted,
                      ),
                      if (progress > 0.005)
                        Padding(
                          padding: const EdgeInsets.only(top: AppSpacing.xxs),
                          child: Row(
                            spacing: AppSpacing.sm,
                            children: [
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(
                                    AppRadius.pill,
                                  ),
                                  child: LinearProgressIndicator(
                                    value: progress > 1 ? 1 : progress,
                                    minHeight: 4,
                                    backgroundColor:
                                        scheme.surfaceContainerHighest,
                                  ),
                                ),
                              ),
                              Text(
                                '${(progress * 100).round()}%',
                                style: muted,
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
