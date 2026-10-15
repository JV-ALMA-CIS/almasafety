import '../../../core/widgets/notification_prompt.dart';
import 'package:flutter/material.dart';
import '../../incidents/data/incident_repository.dart';
import 'package:provider/provider.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../analytics/data/analytics_repository.dart';
import '../../authentication/data/account_approval_service.dart';
import '../../authentication/domain/app_role.dart';
import '../../corrective_actions/data/corrective_action_repository.dart';
import '../../daily_safety_meetings/data/daily_safety_meeting_repository.dart';
import '../../daily_safety_meetings/data/meeting_attendance_repository.dart';
import '../../hazards/data/hazard_repository.dart';
import '../../organizations/data/organization_repository.dart';
import '../../organizations/data/project_repository.dart';
import '../../organizations/data/site_repository.dart';
import '../../safety_learning_compliance/data/safety_compliance_repository.dart';
import '../../safety_requirements/data/safety_requirement_repository.dart';
import 'admin_dashboard_screen.dart';
import 'foreman_dashboard_screen.dart';
import 'site_manager_dashboard_screen.dart';
import 'worker_dashboard_screen.dart';

/// The "Dashboard" nav destination ([AppRoutes.dashboard]) — dispatches to
/// one of four role-specific bodies, mirroring [HazardsRouterScreen]'s and
/// [DailySafetyMeetingsRouterScreen]'s exact "one router screen, N
/// role-gated bodies" dispatch pattern.
///
/// Unlike those two, every one of the four [AppRole] values gets its own
/// body here rather than a two-way reviewer/non-reviewer split — a
/// dashboard's purpose differs meaningfully per role (see each body's own
/// doc comment), not just its read scope.
///
/// A non-Admin role is read from [SessionController.activeMembership] —
/// the same per-organization source every other role-aware screen in this
/// app already uses (a role is per-membership under the multi-organization
/// model, not a scalar profile field). [AppRole.admin] is the sole
/// exception, read from [UserProfile.platformRole], since an Admin holds no
/// organization membership at all.
class DashboardRouterScreen extends StatelessWidget {
  const DashboardRouterScreen({
    super.key,
    this.safetyRequirementRepository,
    this.dailySafetyMeetingRepository,
    this.hazardRepository,
    this.incidentRepository,
    this.correctiveActionRepository,
    this.meetingAttendanceRepositoryFor,
    this.siteRepository,
    this.safetyComplianceRepository,
    this.approvalService,
    this.analyticsRepository,
    this.projectRepository,
    this.organizationRepository,
  });

  /// Injected in tests, threaded through to [WorkerDashboardScreen],
  /// [ForemanDashboardScreen], [SiteManagerDashboardScreen] and
  /// [AdminDashboardScreen]. Production builds pass nothing and every body
  /// constructs its own real dependencies.
  final SafetyRequirementRepository? safetyRequirementRepository;
  final DailySafetyMeetingRepository? dailySafetyMeetingRepository;
  final HazardRepository? hazardRepository;
  final IncidentRepository? incidentRepository;
  final CorrectiveActionRepository? correctiveActionRepository;
  final MeetingAttendanceRepository Function(String meetingId)?
  meetingAttendanceRepositoryFor;
  final SiteRepository? siteRepository;
  final SafetyComplianceRepository? safetyComplianceRepository;
  final AccountApprovalService? approvalService;
  final AnalyticsRepository? analyticsRepository;
  final ProjectRepository? projectRepository;
  final OrganizationRepository? organizationRepository;

  @override
  Widget build(BuildContext context) {
    final sessionController = context.watch<SessionController>();
    final profile = sessionController.profile;
    final isPlatformAdministrator = profile?.isPlatformAdministrator ?? false;

    if (isPlatformAdministrator) {
      return NotificationPrompt(child: _admin(profile?.name, profile?.uid));
    }
    return NotificationPrompt(child: _forRole(sessionController));
  }

  Widget _admin(String? userName, String? userUid) {
    return AdminDashboardScreen(
      userName: userName,
      userUid: userUid,
      analyticsRepository: analyticsRepository,
      hazardRepository: hazardRepository,
      incidentRepository: incidentRepository,
      correctiveActionRepository: correctiveActionRepository,
      siteRepository: siteRepository,
      projectRepository: projectRepository,
      organizationRepository: organizationRepository,
      safetyComplianceRepository: safetyComplianceRepository,
    );
  }

  Widget _forRole(SessionController sessionController) {
    // The profile and membership streams resolve independently — a
    // Foreman/Worker/Site Manager can reach AuthStatus.authenticated (profile
    // loaded) before their OWN membership subscription has reported even
    // once, which previously showed _NoRoleYet's "will appear once you are
    // assigned" message to every authenticated non-Admin for that brief
    // window, even one already fully assigned. membershipsLoaded
    // distinguishes that loading window from a genuine "no membership yet".
    if (!sessionController.membershipsLoaded) {
      return const Center(child: CircularProgressIndicator());
    }

    final role = sessionController.activeMembership?.role;
    return switch (role) {
      AppRole.siteManager => SiteManagerDashboardScreen(
        analyticsRepository: analyticsRepository,
        hazardRepository: hazardRepository,
        incidentRepository: incidentRepository,
        siteRepository: siteRepository,
        safetyComplianceRepository: safetyComplianceRepository,
      ),
      AppRole.foreman => ForemanDashboardScreen(
        siteRepository: siteRepository,
        dailySafetyMeetingRepository: dailySafetyMeetingRepository,
        hazardRepository: hazardRepository,
        incidentRepository: incidentRepository,
        correctiveActionRepository: correctiveActionRepository,
        safetyComplianceRepository: safetyComplianceRepository,
        approvalService: approvalService,
      ),
      AppRole.worker => WorkerDashboardScreen(
        safetyRequirementRepository: safetyRequirementRepository,
        dailySafetyMeetingRepository: dailySafetyMeetingRepository,
        hazardRepository: hazardRepository,
        incidentRepository: incidentRepository,
        correctiveActionRepository: correctiveActionRepository,
        meetingAttendanceRepositoryFor: meetingAttendanceRepositoryFor,
      ),
      // Admin is handled above via isPlatformAdministrator (org-less by
      // construction); null means no membership resolved yet (e.g. a
      // brand-new account between approval and its first organization) —
      // shown a simple explanatory message rather than crashing on a role
      // that doesn't exist yet.
      AppRole.admin || null => const _NoRoleYet(),
    };
  }
}

class _NoRoleYet extends StatelessWidget {
  const _NoRoleYet();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(AppSpacing.lg),
        child: Text(
          'Your dashboard will appear once you are assigned to an '
          'organization.',
          style: AppTextStyles.bodyMedium,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
