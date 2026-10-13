import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/services/session_controller.dart';
import '../data/corrective_action_repository.dart';
import '../data/corrective_action_service.dart';
import '../../organizations/data/organization_repository.dart';
import '../../organizations/data/site_repository.dart';
import 'corrective_actions_screen.dart';
import 'my_corrective_actions_screen.dart';

/// The "Corrective Actions" nav destination
/// ([AppRoutes.correctiveActions]) — dispatches to the right screen for the
/// signed-in user's own role, mirroring [HazardsRouterScreen]'s exact
/// dispatch.
///
/// Any role for which [AppRole.canReviewPendingAccounts] is true —
/// `admin`/`siteManager`/`foreman`, the same reviewer set
/// `corrective_action_callable.ts`'s `requireOrganizationScopedReviewer`
/// accepts for `updateCorrectiveActionStatus` — gets
/// [CorrectiveActionsScreen], the organization-wide review list. Everyone
/// else (a `worker`, or a `foreman` without review authority in this
/// deployment) gets [MyCorrectiveActionsScreen], their own "what's assigned
/// to me" list, scoped by `assignedTo`.
class CorrectiveActionsRouterScreen extends StatelessWidget {
  const CorrectiveActionsRouterScreen({
    super.key,
    this.repository,
    this.service,
    this.siteRepository,
    this.organizationRepository,
  });

  /// Injected in tests. Production builds pass nothing and each destination
  /// screen constructs its own real dependencies.
  final CorrectiveActionRepository? repository;
  final CorrectiveActionService? service;
  final SiteRepository? siteRepository;
  final OrganizationRepository? organizationRepository;

  @override
  Widget build(BuildContext context) {
    final sessionController = context.watch<SessionController>();
    final profile = sessionController.profile;
    final isPlatformAdministrator = profile?.isPlatformAdministrator ?? false;
    final canManage =
        isPlatformAdministrator ||
        (sessionController.activeMembership?.role.canReviewPendingAccounts ??
            false);

    if (!canManage) {
      return MyCorrectiveActionsScreen(
        repository: repository,
        service: service,
      );
    }
    return CorrectiveActionsScreen(
      repository: repository,
      service: service,
      siteRepository: siteRepository,
      organizationRepository: organizationRepository,
    );
  }
}
