import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../domain/pre_start_outcome.dart';

/// How each [PreStartOutcome] looks everywhere it appears — worker card,
/// crew card, meeting completion — so GO / GO corrected / STOP are always
/// the same color and icon.
extension PreStartOutcomeStyle on PreStartOutcome {
  Color get color => switch (this) {
    PreStartOutcome.go => AppColors.go,
    PreStartOutcome.goCorrected => AppColors.goCorrected,
    PreStartOutcome.stop => AppColors.stop,
  };

  IconData get icon => switch (this) {
    PreStartOutcome.go => Icons.check_circle,
    PreStartOutcome.goCorrected => Icons.build_circle,
    PreStartOutcome.stop => Icons.front_hand,
  };
}

/// A compact solid "Crew: GO" badge for a completed meeting's crew result,
/// shown in meeting lists and summaries.
class CrewOutcomeBadge extends StatelessWidget {
  const CrewOutcomeBadge({super.key, required this.outcome});

  final PreStartOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final foreground = AppColors.onColor(outcome.color);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: outcome.color,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(outcome.icon, size: 16, color: foreground),
          const SizedBox(width: 4),
          Text(
            'Crew: ${outcome.label}',
            style: TextStyle(
              color: foreground,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// The large colored GO / GO corrected / STOP panel: icon, label and the
/// outcome's plain-language description.
class PreStartOutcomePanel extends StatelessWidget {
  const PreStartOutcomePanel({super.key, required this.outcome, this.footer});

  final PreStartOutcome outcome;

  /// Optional extra content under the description, e.g. the worker's notes.
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final foreground = AppColors.onColor(outcome.color);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: outcome.color,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(outcome.icon, color: foreground, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  outcome.label,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            outcome.description,
            style: TextStyle(color: foreground, fontSize: 16),
          ),
          if (footer != null) ...[const SizedBox(height: 12), footer!],
        ],
      ),
    );
  }
}
