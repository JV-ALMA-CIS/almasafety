import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';

/// A small pill-shaped status label — the color+label chip repeated,
/// previously duplicated per-screen, across `HazardsManagementScreen`,
/// `MyHazardsScreen`, `CorrectiveActionsScreen`, `MyCorrectiveActionsScreen`,
/// `MySafetyLearningScreen` and `LearningDetailScreen`'s own local
/// `_StatusBadge` classes.
///
/// Deliberately takes [label]/[color] directly rather than a status enum:
/// each feature's own status-to-color mapping is domain knowledge that
/// belongs with that feature's status enum, not centralized here — this
/// widget only standardizes the visual presentation once that mapping has
/// already been decided by the caller.
///
/// Drawn as a solid fill with contrasting text ([AppColors.onColor]) so the
/// status is the boldest thing on its row.
class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm + 2,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: AppTextStyles.label.copyWith(color: AppColors.onColor(color)),
      ),
    );
  }
}
