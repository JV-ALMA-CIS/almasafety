import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';

/// A single number + label + icon — the smallest reusable dashboard
/// building block, e.g. "12 / Open Hazards". Purely presentational: the
/// caller resolves [value] from whatever stream/aggregate is authoritative
/// for it (this widget performs no counting or querying itself).
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.value,
    required this.label,
    required this.icon,
    this.color,
  });

  final String value;
  final String label;
  final IconData icon;

  /// The tile's accent: fills the icon badge and tints the value. Omit for
  /// the brand accent ([AppColors.dashboard]).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final accent = color ?? AppColors.dashboard;
    final brightness = Theme.of(context).brightness;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(AppSpacing.sm),
          decoration: BoxDecoration(
            color: accent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: AppColors.onColor(accent), size: 22),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          value,
          style: AppTextStyles.headlineMedium.copyWith(
            color: AppColors.readable(accent, brightness),
          ),
        ),
        const SizedBox(height: 2),
        Text(label, style: AppTextStyles.bodyMedium),
      ],
    );
  }
}
