import 'package:flutter/material.dart';
import '../../features/authentication/domain/app_role.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';

/// The brand-gradient banner at the top of every role's dashboard. It says
/// plainly whose dashboard this is: a solid [role] badge in that role's
/// color, the screen [title], and the signed-in [userName]. An optional
/// [subtitle] adds context (e.g. the Admin's organization overview), and a
/// large faded [icon] marks the role.
class DashboardHeader extends StatelessWidget {
  const DashboardHeader({
    super.key,
    required this.title,
    required this.role,
    this.userName,
    this.subtitle,
    this.icon = Icons.health_and_safety,
  });

  final String title;
  final AppRole role;
  final String? userName;
  final String? subtitle;
  final IconData icon;

  /// Each role's badge color — distinct from one another and readable on
  /// the brand gradient.
  static Color roleColor(AppRole role) => switch (role) {
    AppRole.admin => AppColors.administration,
    AppRole.siteManager => AppColors.secondary,
    AppRole.foreman => AppColors.hazards,
    AppRole.worker => AppColors.people,
  };

  @override
  Widget build(BuildContext context) {
    final badgeColor = roleColor(role);
    final name = userName?.trim() ?? '';
    return Container(
      decoration: BoxDecoration(
        gradient: AppColors.brandGradient,
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned(
            right: -12,
            bottom: -18,
            child: Icon(
              icon,
              size: 110,
              color: Colors.white.withValues(alpha: 0.14),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md + 4,
              AppSpacing.md + 4,
              AppSpacing.md + 4,
              AppSpacing.md + 4,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm + 2,
                    vertical: AppSpacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: badgeColor,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        icon,
                        size: 16,
                        color: AppColors.onColor(badgeColor),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Flexible(
                        child: Text(
                          role.label,
                          style: AppTextStyles.label.copyWith(
                            color: AppColors.onColor(badgeColor),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  title,
                  style: AppTextStyles.headlineMedium.copyWith(
                    color: Colors.white,
                  ),
                ),
                if (name.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Row(
                    children: [
                      const Icon(
                        Icons.account_circle,
                        size: 20,
                        color: Colors.white,
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Expanded(
                        child: Text(
                          name,
                          style: AppTextStyles.bodyLarge.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                if (subtitle != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    subtitle!,
                    style: AppTextStyles.bodyMedium.copyWith(
                      color: Colors.white.withValues(alpha: 0.85),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
