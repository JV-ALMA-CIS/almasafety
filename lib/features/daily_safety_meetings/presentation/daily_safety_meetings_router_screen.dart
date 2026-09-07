import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/session_controller.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../authentication/data/account_approval_service.dart';
import '../../organizations/data/organization_repository.dart';
import '../../organizations/data/project_repository.dart';
import '../../organizations/data/site_repository.dart';
import '../../organizations/domain/organization.dart';
import '../data/daily_safety_meeting_repository.dart';
import 'admin_daily_safety_meetings_screen.dart';
import 'daily_safety_meeting_screen.dart';

/// The bottom-nav "Meetings" destination ([AppRoutes.dailySafetyMeetings]) —
/// dispatches to the right screen for the signed-in user's own role, rather
/// than assuming every visitor is a foreman.
///
/// A [AppRole.foreman] gets [DailySafetyMeetingScreen], their own
/// operational meeting workspace, unchanged. Any role for which
/// [AppRole.canReviewDailySafetyMeetings] is true — [AppRole.siteManager] —
/// gets [AdminDailySafetyMeetingsScreen] for their own organization instead,
/// so "Meetings" in the nav bar means "the meetings I need to see" for
/// whoever is signed in, not just the foreman-only workspace. Previously a
/// Superintendent (etc.) had to know to go via Administration →
/// Organizations → their org → "Daily Safety Meetings" instead — a path
/// that exists for an Admin reviewing an *other* organization, but is not
/// the natural or reachable one for a reviewer looking at their own site's
/// meetings day to day.
///
/// [AppRole.admin] and [AppRole.worker] are unaffected by this dispatch: an
/// Admin has no organization of their own to resolve here (they already
/// reach every organization's meetings through the Administration
/// drill-down), and a worker holds neither capability, so both fall through
/// to the existing "not available" messaging.
class DailySafetyMeetingsRouterScreen extends StatelessWidget {
  const DailySafetyMeetingsRouterScreen({
    super.key,
    this.organizationRepository,
    this.firestoreService,
    this.meetingRepository,
    this.projectRepository,
    this.siteRepository,
    this.approvalService,
  });

  /// Injected in tests. Production builds pass nothing and the state
  /// constructs the real dependency.
  final OrganizationRepository? organizationRepository;

  /// Injected in tests, and threaded through to
  /// [AdminDailySafetyMeetingsScreen] for a reviewer role so a test's fake
  /// Firestore instance backs the whole drill-down, matching how
  /// [AdminDailySafetyMeetingsScreen] itself threads these through to
  /// [DailySafetyMeetingSummaryScreen]. Production builds pass nothing and
  /// every repository resolves the real Firebase instance lazily.
  final FirestoreService? firestoreService;
  final DailySafetyMeetingRepository? meetingRepository;
  final ProjectRepository? projectRepository;
  final SiteRepository? siteRepository;
  final AccountApprovalService? approvalService;

  @override
  Widget build(BuildContext context) {
    final sessionController = context.watch<SessionController>();
    final profile = sessionController.profile;
    // A reviewer's role now lives on their active Membership for every role
    // except admin (whose platformRole carries it, org-less by
    // construction) — see UserProfile's doc comment on the multi-org model.
    final role =
        profile?.platformRole ?? sessionController.activeMembership?.role;
    final organizationId = sessionController.activeOrganizationId;

    if (role == null || !role.canReviewDailySafetyMeetings) {
      return const DailySafetyMeetingScreen();
    }

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

        return AdminDailySafetyMeetingsScreen(
          organization: organization,
          firestoreService: firestoreService,
          meetingRepository: meetingRepository,
          projectRepository: projectRepository,
          siteRepository: siteRepository,
          approvalService: approvalService,
        );
      },
    );
  }
}
