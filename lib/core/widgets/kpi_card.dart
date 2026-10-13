import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import 'stat_tile.dart';

/// A [StatTile] wrapped in a [Card], optionally tappable — a dashboard's
/// standard "drill into this KPI" affordance, e.g. tapping an "Open
/// Hazards" tile to reach the filtered Hazards list. The card is washed
/// with the tile's accent [color] and bordered in it, so each KPI reads by
/// color at a glance.
class KpiCard extends StatelessWidget {
  const KpiCard({
    super.key,
    required this.value,
    required this.label,
    required this.icon,
    this.color,
    this.onTap,
  });

  final String value;
  final String label;
  final IconData icon;
  final Color? color;

  /// Navigates to the detail screen this KPI summarizes, when given. Omit
  /// for a purely informational tile with nothing to drill into.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final accent = color ?? AppColors.dashboard;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final radius = BorderRadius.circular(12);
    return Card(
      margin: EdgeInsets.zero,
      color: Color.alphaBlend(
        accent.withValues(alpha: isDark ? 0.18 : 0.09),
        theme.colorScheme.surface,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: accent.withValues(alpha: 0.45)),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: StatTile(value: value, label: label, icon: icon, color: color),
        ),
      ),
    );
  }
}
