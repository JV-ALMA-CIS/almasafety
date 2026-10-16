import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';

/// A bright note that an entry was saved on this phone because there was no
/// signal, and will be sent automatically (see `Outbox`).
class SavedOnPhoneNote extends StatelessWidget {
  const SavedOnPhoneNote({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    const color = AppColors.secondary;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          color.withValues(alpha: 0.16),
          Theme.of(context).colorScheme.surface,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color, width: 2),
      ),
      child: Row(
        children: [
          const Icon(Icons.cloud_upload_outlined, color: color, size: 32),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(text, style: AppTextStyles.bodyLarge)),
        ],
      ),
    );
  }
}
