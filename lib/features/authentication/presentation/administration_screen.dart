import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../routing/app_routes.dart';
import '../domain/app_role.dart';

/// The administrative dashboard: the entry point for platform- and
/// organization-level administrative tasks.
///
/// Reachable by [UserProfile.isPlatformAdministrator] (a System
/// Admin, platform-wide) or an [AppRole.siteManager]
/// (scoped to their own organization) — matching [OrganizationsScreen]'s own
/// `canManage`/`isPlatformAdministrator` getters, since Organizations is this
/// screen's fourth entry point. As with [PendingApprovalsScreen], that check
/// is UX only: the router redirects everyone else away, and this widget
/// renders nothing useful without it, but neither is the enforcement
/// boundary — a modified client that reached this screen anyway would still
/// have no more Firestore reach than its own role and organization grant,
/// exactly as `firestore.rules` and the Cloud Functions callables decide it
/// independently.
///
/// Three entry points, matching the three states a reviewed user can be in:
///
///  - Pending Approvals — [PendingApprovalsScreen]: approve/reject
///    registrations, assigning organization, role and worker type.
///  - Active Users — [OrganizationUsersScreen]: already-active accounts,
///    with a Suspend action.
///  - Suspended/Rejected Users — [OrganizationUsersScreen]: withdrawn
///    accounts, with a Reinstate action for a suspended one (rejection is
///    terminal).
///
/// A fourth entry point, Organizations — [OrganizationsScreen] — leads to
/// the Organization -> Project -> Site -> Site Workers chain. An Organization
/// Administrator reaching it sees only their own organization and cannot
/// create/edit a project or site (`createProject`/`updateProject`/
/// `createSite`/`updateSite` remain System-Administrator-only server-side),
/// but can reach Site Workers to assign/remove workers at their own sites —
/// see [SitesScreen]/[SiteWorkersScreen]'s doc comments.
class AdministrationScreen extends StatelessWidget {
  const AdministrationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final profile = context.watch<SessionController>().profile;
    final isPlatformAdministrator = profile?.isPlatformAdministrator ?? false;
    final canManage = isPlatformAdministrator ||
        profile?.canManageOrgContent == true;

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
        Text('Administration', style: AppTextStyles.headlineMedium),
        const SizedBox(height: AppSpacing.xs),
        const Text(
          'Review, approve and manage user accounts.',
          style: AppTextStyles.bodyMedium,
        ),
        const SizedBox(height: AppSpacing.lg),
        _AdministrationEntry(
          icon: Icons.how_to_reg_outlined,
          title: 'Pending Approvals',
          subtitle: 'Review registrations and assign organization, role '
              'and worker type.',
          onTap: () => context.go(AppRoutes.pendingApprovals),
        ),
        const SizedBox(height: AppSpacing.sm),
        _AdministrationEntry(
          icon: Icons.groups_outlined,
          title: 'Active Users',
          subtitle: 'View active accounts and suspend one if needed.',
          onTap: () => context.go(AppRoutes.activeUsers),
        ),
        const SizedBox(height: AppSpacing.sm),
        _AdministrationEntry(
          icon: Icons.person_off_outlined,
          title: 'Suspended / Rejected Users',
          subtitle: 'View suspended and rejected accounts, and reinstate a '
              'suspended one if needed.',
          onTap: () => context.go(AppRoutes.suspendedUsers),
        ),
        const SizedBox(height: AppSpacing.sm),
        _AdministrationEntry(
          icon: Icons.corporate_fare_outlined,
          title: 'Organizations',
          subtitle: 'View organizations and manage their sites\' assigned '
              'workers.',
          onTap: () => context.go(AppRoutes.manageOrganizations),
        ),
      ],
    );
  }
}

class _AdministrationEntry extends StatelessWidget {
  const _AdministrationEntry({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        onTap: onTap,
      ),
    );
  }
}
