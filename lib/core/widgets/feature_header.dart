import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';

/// One small info pill on a [FeatureHeader], e.g. 📍 "Site A".
class FeatureChip {
  const FeatureChip({required this.icon, required this.label});

  final IconData icon;
  final String label;
}

/// The colored banner at the top of a feature screen — Today's Safety
/// Readiness, a lesson, Today's Meeting, Approvals, My Workers — in that
/// feature's own accent ([AppColors] "Feature accents"), so each screen is
/// recognisable at a glance and matches its nav entry and dashboard tiles.
///
/// Shows a large faded [icon], an optional [eyebrow] line above the
/// [title], a [subtitle], a row of [chips] (project, site, counts…), and an
/// optional [trailing] widget (a status badge or an action).
///
/// The banner IS the screen's title. A screen opened on top of the app
/// (a form or detail page) therefore uses a title-less `AppBar()` — just
/// the back/close button — so the title is never shown twice.
class FeatureHeader extends StatelessWidget {
  const FeatureHeader({
    super.key,
    required this.title,
    required this.icon,
    required this.color,
    this.eyebrow,
    this.subtitle,
    this.chips = const [],
    this.trailing,
    this.footer,
  });

  final String title;
  final IconData icon;
  final Color color;
  final String? eyebrow;
  final String? subtitle;
  final List<FeatureChip> chips;
  final Widget? trailing;

  /// Optional content under the chips, e.g. an action button.
  final Widget? footer;

  @override
  Widget build(BuildContext context) => _buildFull();

  Widget _chipWrap(Color foreground) {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        for (final chip in chips)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: foreground.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: foreground.withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(chip.icon, size: 16, color: foreground),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    chip.label,
                    style: AppTextStyles.label.copyWith(color: foreground),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildFull() {
    final foreground = AppColors.onColor(color);
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(color, Colors.black, 0.18)!,
            Color.lerp(color, Colors.white, 0.12)!,
          ],
        ),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.25),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned(
            right: -16,
            bottom: -24,
            child: Icon(
              icon,
              size: 120,
              color: foreground.withValues(alpha: 0.12),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md + 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: foreground.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(icon, color: foreground, size: 26),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (eyebrow != null)
                            Text(
                              eyebrow!.toUpperCase(),
                              style: AppTextStyles.label.copyWith(
                                color: foreground.withValues(alpha: 0.85),
                                letterSpacing: 1.2,
                              ),
                            ),
                          Text(
                            title,
                            style: AppTextStyles.headlineMedium.copyWith(
                              color: foreground,
                            ),
                          ),
                          if (subtitle != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              subtitle!,
                              style: AppTextStyles.bodyMedium.copyWith(
                                color: foreground.withValues(alpha: 0.92),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (trailing != null) ...[
                      const SizedBox(width: AppSpacing.sm),
                      trailing!,
                    ],
                  ],
                ),
                if (chips.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.md),
                  _chipWrap(foreground),
                ],
                if (footer != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  footer!,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A colored section heading inside a feature screen: a filled icon badge,
/// the [title], an optional [count] pill and [trailing] action — the
/// in-screen counterpart of [FeatureHeader].
class FeatureSectionTitle extends StatelessWidget {
  const FeatureSectionTitle({
    super.key,
    required this.title,
    required this.icon,
    required this.color,
    this.count,
    this.trailing,
  });

  final String title;
  final IconData icon;
  final Color color;
  final int? count;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 18, color: AppColors.onColor(color)),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(child: Text(title, style: AppTextStyles.titleLarge)),
        if (count != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '$count',
              style: AppTextStyles.label.copyWith(
                color: AppColors.onColor(color),
              ),
            ),
          ),
        ?trailing,
      ],
    );
  }
}
