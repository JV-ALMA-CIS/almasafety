import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import 'status_badge.dart';

/// One icon + text detail line on an [AccentCard], e.g. 📍 "Site A".
class AccentDetail {
  const AccentDetail({required this.icon, required this.text});

  final IconData icon;
  final String text;
}

/// A label + color pair shown as a solid [StatusBadge] on an [AccentCard].
class AccentBadge {
  const AccentBadge({required this.label, required this.color});

  final String label;
  final Color color;
}

/// The colorful list card used across feature screens (alerts, corrective
/// actions, hazards, notifications, projects…): a solid [color] stripe down
/// the left edge, a filled [icon] badge in the same color, a bold [title],
/// solid [badges], an optional [body], icon-labelled [details] and
/// [actions] — so each item reads by color before it is read by text.
class AccentCard extends StatelessWidget {
  const AccentCard({
    super.key,
    required this.color,
    required this.icon,
    required this.title,
    this.badges = const [],
    this.body,
    this.details = const [],
    this.actions = const [],
    this.onTap,
    this.trailing,
    this.dimmed = false,
  });

  final Color color;
  final IconData icon;
  final String title;
  final List<AccentBadge> badges;
  final String? body;
  final List<AccentDetail> details;
  final List<Widget> actions;
  final VoidCallback? onTap;
  final Widget? trailing;

  /// Softens a finished/closed item so open ones stand out.
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(14);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Opacity(
      opacity: dimmed ? 0.7 : 1,
      child: Card(
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: color.withValues(alpha: 0.35)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 6, color: color),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: color,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                icon,
                                size: 20,
                                color: AppColors.onColor(color),
                              ),
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(title, style: AppTextStyles.titleLarge),
                                  if (badges.isNotEmpty) ...[
                                    const SizedBox(height: AppSpacing.xs),
                                    Wrap(
                                      spacing: AppSpacing.xs,
                                      runSpacing: AppSpacing.xs,
                                      children: [
                                        for (final badge in badges)
                                          StatusBadge(
                                            label: badge.label,
                                            color: badge.color,
                                          ),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            ?trailing,
                          ],
                        ),
                        if (body != null && body!.isNotEmpty) ...[
                          const SizedBox(height: AppSpacing.sm),
                          Text(body!, style: AppTextStyles.bodyLarge),
                        ],
                        if (details.isNotEmpty) ...[
                          const SizedBox(height: AppSpacing.sm),
                          for (final detail in details)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Row(
                                children: [
                                  Icon(detail.icon, size: 16, color: muted),
                                  const SizedBox(width: AppSpacing.xs),
                                  Expanded(
                                    child: Text(
                                      detail.text,
                                      style: AppTextStyles.bodyMedium.copyWith(
                                        color: muted,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                        if (actions.isNotEmpty) ...[
                          const SizedBox(height: AppSpacing.md),
                          Wrap(
                            spacing: AppSpacing.sm,
                            runSpacing: AppSpacing.sm,
                            children: actions,
                          ),
                        ],
                      ],
                    ),
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

/// A filled action button in [color] for an [AccentCard]'s actions — sized
/// for the field (48px tall) without stretching across the card.
class AccentButton extends StatelessWidget {
  const AccentButton({
    super.key,
    required this.label,
    required this.icon,
    required this.color,
    required this.onPressed,
    this.outlined = false,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback? onPressed;
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    const size = Size(0, AppSpacing.minTouchTarget);
    if (outlined) {
      return OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          minimumSize: size,
          foregroundColor: AppColors.readable(
            color,
            Theme.of(context).brightness,
          ),
          side: BorderSide(color: color, width: 1.5),
        ),
        onPressed: onPressed,
        icon: Icon(icon),
        label: Text(label),
      );
    }
    return ElevatedButton.icon(
      style: ElevatedButton.styleFrom(
        minimumSize: size,
        backgroundColor: color,
        foregroundColor: AppColors.onColor(color),
      ),
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
    );
  }
}

/// The small filled square that leads a card's title row — an [icon] or an
/// [emoji] on the card's accent [color].
class AccentIconBadge extends StatelessWidget {
  const AccentIconBadge({
    super.key,
    required this.color,
    this.icon,
    this.emoji,
  });

  final Color color;
  final IconData? icon;
  final String? emoji;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: emoji != null ? color.withValues(alpha: 0.15) : color,
        borderRadius: BorderRadius.circular(10),
      ),
      child: emoji != null
          ? Text(emoji!, style: const TextStyle(fontSize: 22))
          : Icon(icon, size: 22, color: AppColors.onColor(color)),
    );
  }
}
