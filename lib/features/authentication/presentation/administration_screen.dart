import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../routing/app_routes.dart';
import '../domain/app_role.dart';
import '../../../core/widgets/feature_header.dart';
import '../../../core/theme/app_colors.dart';

/// The administrative dashboard: the entry point for account-review tasks
/// (pending approvals, active/suspended users).
///
/// Reachable by [UserProfile.isPlatformAdministrator] (a System
/// Admin, platform-wide) or an [AppRole.siteManager]
/// (JV ALMA CIS-wide, per the single-company model — see
/// [SessionController]'s PHASE 1 doc comment). As with
/// [PendingApprovalsScreen], that check is UX only: the router redirects
/// everyone else away, and this widget renders nothing useful without it,
/// but neither is the enforcement boundary — a modified client that reached
/// this screen anyway would still have no more Firestore reach than its own
/// role grant, exactly as `firestore.rules` and the Cloud Functions
/// callables decide it independently.
///
/// Two entry points, matching the two states a reviewed user can be in:
///
///  - Pending Approvals — [PendingApprovalsScreen]: approve/reject
///    registrations, assigning role and worker type.
///  - Active Users — [OrganizationUsersScreen]: already-active accounts,
///    with a Suspend action.
///  - Suspended/Rejected Users — [OrganizationUsersScreen]: withdrawn
///    accounts, with a Reinstate action for a suspended one (rejection is
///    terminal).
///
/// PHASE 1: this screen previously had a fourth entry, "Organizations",
/// leading to the Organization -> Project -> Site -> Site Workers chain —
/// removed under the single-company model (JV ALMA CIS is the one company
/// every user works under, not a list to browse). That chain is still
/// reachable, just starting from Projects directly (the sidebar's
/// Operations -> Projects entry, [ProjectsRouterScreen]) rather than from
/// an Organizations list — see [SitesScreen]/[SiteWorkersScreen]'s doc
/// comments for what's still reachable from there.
class AdministrationScreen extends StatelessWidget {
  const AdministrationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final sessionController = context.watch<SessionController>();
    final profile = sessionController.profile;
    final isPlatformAdministrator = profile?.isPlatformAdministrator ?? false;
    // A non-Admin's role (including canManageOrgContent) now lives on their
    // active Membership, not the (now admin-only) profile.platformRole —
    // except for the one transient case of a Site Manager just approved
    // with no organization yet, who has no membership at all and is
    // signalled instead by profile.platformRole == siteManager (see
    // account_approval.ts's approveAccount). Without this fallback, that
    // Site Manager could never reach the one screen (Organizations, below)
    // that gives them their first membership.
    final canManage =
        isPlatformAdministrator ||
        (sessionController.activeMembership?.role.canManageOrgContent ??
            false) ||
        profile?.platformRole == AppRole.siteManager;

    if (!canManage) {
      // Defence in depth: the router should never route an unauthorized
      // user here.
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Text(
            'You do not have permission to view administration.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        const FeatureHeader(
          title: 'Administration',
          subtitle: 'Review, approve and manage user accounts.',
          icon: Icons.admin_panel_settings,
          color: AppColors.administration,
        ),
        const SizedBox(height: AppSpacing.lg),
        const FeatureSectionTitle(
          title: 'User accounts',
          icon: Icons.manage_accounts,
          color: AppColors.administration,
        ),
        const SizedBox(height: AppSpacing.sm),
        _AdministrationEntry(
          color: AppColors.warning,
          icon: Icons.how_to_reg,
          title: 'Pending Approvals',
          subtitle: 'Review registrations and assign role and worker type.',
          onTap: () => context.go(AppRoutes.pendingApprovals),
        ),
        const SizedBox(height: AppSpacing.sm),
        _AdministrationEntry(
          color: AppColors.people,
          icon: Icons.groups,
          title: 'Active Users',
          subtitle: 'View active accounts and suspend one if needed.',
          onTap: () => context.go(AppRoutes.activeUsers),
        ),
        const SizedBox(height: AppSpacing.sm),
        _AdministrationEntry(
          color: AppColors.danger,
          icon: Icons.person_off,
          title: 'Suspended / Rejected Users',
          subtitle:
              'View suspended and rejected accounts, and reinstate a '
              'suspended one if needed.',
          onTap: () => context.go(AppRoutes.suspendedUsers),
        ),
      ],
    );
  }
}

class _AdministrationEntry extends StatelessWidget {
  const _AdministrationEntry({
    required this.color,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final Color color;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      color: Color.alphaBlend(
        color.withValues(alpha: 0.08),
        Theme.of(context).colorScheme.surface,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: color.withValues(alpha: 0.5)),
      ),
      child: ListTile(
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: AppColors.onColor(color)),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(subtitle),
        trailing: Icon(Icons.chevron_right, color: color),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        onTap: onTap,
      ),
    );
  }
}
