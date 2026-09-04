import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

/// Marks content that was generated or suggested by Gemini so it is always
/// visually distinguishable from verified operational records.
///
/// Any AI-generated summary, recommendation, or classification shown in the
/// UI must be wrapped with or accompanied by this badge — never presented as
/// if it were a foreman-recorded or otherwise verified fact.
class AiGeneratedBadge extends StatelessWidget {
  const AiGeneratedBadge({super.key, this.label = 'AI-generated'});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.info.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.info.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.auto_awesome, size: 14, color: AppColors.info),
          const SizedBox(width: 4),
          Text(
            label,
            style: AppTextStyles.label.copyWith(color: AppColors.info),
          ),
        ],
      ),
    );
  }
}
