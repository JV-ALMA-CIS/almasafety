import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';

/// A titled section of dashboard content — a heading, an optional
/// trailing action (e.g. "See all"), and a body. Matches the
/// `Text(..., style: AppTextStyles.titleLarge)` heading convention already
/// used ad hoc across the app's list screens, centralized here so every
/// dashboard section looks the same without each phase re-deriving the
/// spacing.
///
/// The heading leads with the section's feature [color] — as a filled
/// [icon] badge when one is given, otherwise as a short accent bar — so the
/// section and the KPI tiles inside it share one color.
class DashboardSection extends StatelessWidget {
  const DashboardSection({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.color,
    this.icon,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  /// The section's feature accent; defaults to [AppColors.secondary].
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final accent = color ?? AppColors.secondary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (icon != null)
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 18, color: AppColors.onColor(accent)),
              )
            else
              Container(
                width: 5,
                height: 22,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: Text(title, style: AppTextStyles.titleLarge)),
            ?trailing,
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        child,
      ],
    );
  }
}
