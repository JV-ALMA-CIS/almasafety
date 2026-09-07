import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../data/organization_admin_service.dart';
import '../data/organization_repository.dart';
import '../data/project_repository.dart';
import '../domain/organization.dart';
import 'projects_screen.dart';

/// The sidebar's "Projects" destination ([AppRoutes.projects]) — resolves
/// the signed-in user's own active organization and shows [ProjectsScreen]
/// for it directly, without requiring a prior Organizations-list drill-down.
///
/// Mirrors [DailySafetyMeetingsRouterScreen]'s shape exactly: a top-level
/// nav destination that needs an [Organization] object, which
/// [ProjectsScreen] otherwise only receives via `extra` from a card tap on
/// [OrganizationsScreen]. Reading `SessionController.activeOrganizationId`
/// and resolving that one document directly makes Projects reachable from
/// the primary navigation instead of only through the Administration
/// drill-down, while [ProjectsScreen] itself is unchanged.
///
/// A caller with no active organization yet (zero memberships — the
/// documented "create your own org afterward" window for a brand-new Site
/// Manager, or a Foreman/Worker whose account has not been placed anywhere)
/// sees a message instead of an empty/loading screen.
class ProjectsRouterScreen extends StatelessWidget {
  const ProjectsRouterScreen({
    super.key,
    this.organizationRepository,
    this.firestoreService,
    this.projectRepository,
    this.adminService,
  });

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependency.
  final OrganizationRepository? organizationRepository;

  /// Threaded through to [ProjectsScreen] so a test's fake Firestore
  /// instance backs the whole resolve-then-render chain, matching
  /// [DailySafetyMeetingsRouterScreen]'s own injection pattern.
  final FirestoreService? firestoreService;
  final ProjectRepository? projectRepository;
  final OrganizationAdminService? adminService;

  @override
  Widget build(BuildContext context) {
    final sessionController = context.watch<SessionController>();
    final organizationId = sessionController.activeOrganizationId;

    if (organizationId == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Text(
            'Your account is not yet assigned to an organization.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final resolvedFirestoreService = firestoreService ?? FirestoreService();
    final repository = organizationRepository ??
        OrganizationRepository(firestoreService: resolvedFirestoreService);

    return StreamBuilder<Organization?>(
      stream: repository.watchById(organizationId),
      builder: (context, snapshot) {
        final organization = snapshot.data;
        final isLoading =
            snapshot.connectionState == ConnectionState.waiting;

        if (isLoading && organization == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (organization == null) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.lg),
              child: Text(
                'Could not load your organization. Please try again.',
                style: AppTextStyles.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        return ProjectsScreen(
          organization: organization,
          repository: projectRepository,
          adminService: adminService,
        );
      },
    );
  }
}
