import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/services/session_controller.dart';
import '../../authentication/data/account_approval_service.dart';
import '../../corrective_actions/data/corrective_action_repository.dart';
import '../../organizations/data/organization_repository.dart';
import '../../organizations/data/site_repository.dart';
import '../data/hazard_repository.dart';
import '../data/hazard_service.dart';
import 'hazards_management_screen.dart';
import 'my_hazards_screen.dart';

/// The "Hazards" nav destination ([AppRoutes.hazards]) — dispatches to the
/// right screen for the signed-in user's own role, mirroring
/// [DailySafetyMeetingsRouterScreen]'s exact "Meetings" dispatch.
///
/// Any role for which [AppRole.canReviewPendingAccounts] is true —
/// `admin`/`siteManager`/`foreman`, the same reviewer set
/// `hazard_callable.ts`'s `requireOrganizationScopedReviewer` accepts for
/// `acknowledgeHazard`/`linkHazardCorrectiveAction`/`closeHazard` — gets
/// [HazardsManagementScreen], the organization-wide triage view. Everyone
/// else (a `worker`, or a `foreman` without review authority in this
/// deployment) gets [MyHazardsScreen], their own read-only "what have I
/// reported" list, unchanged.
class HazardsRouterScreen extends StatelessWidget {
  const HazardsRouterScreen({
    super.key,
    this.hazardRepository,
    this.hazardService,
    this.siteRepository,
    this.organizationRepository,
    this.correctiveActionRepository,
    this.approvalService,
  });

  /// Injected in tests. Production builds pass nothing and each destination
  /// screen constructs its own real dependencies.
  final HazardRepository? hazardRepository;
  final HazardService? hazardService;
  final SiteRepository? siteRepository;
  final OrganizationRepository? organizationRepository;
  final CorrectiveActionRepository? correctiveActionRepository;
  final AccountApprovalService? approvalService;

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
      return MyHazardsScreen(hazardRepository: hazardRepository);
    }
    return HazardsManagementScreen(
      repository: hazardRepository,
      service: hazardService,
      siteRepository: siteRepository,
      organizationRepository: organizationRepository,
      correctiveActionRepository: correctiveActionRepository,
      approvalService: approvalService,
    );
  }
}
