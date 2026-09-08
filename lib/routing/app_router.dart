import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../core/services/session_controller.dart';
import '../core/widgets/placeholder_screen.dart';
import '../features/authentication/domain/account_status.dart';
import '../features/authentication/presentation/access_denied_screen.dart';
import '../features/authentication/presentation/administration_screen.dart';
import '../features/authentication/presentation/login_screen.dart';
import '../features/authentication/presentation/organization_users_screen.dart';
import '../features/authentication/presentation/pending_approval_screen.dart';
import '../features/authentication/presentation/pending_approvals_screen.dart';
import '../features/authentication/presentation/register_screen.dart';
import '../features/authentication/presentation/session_loading_screen.dart';
import '../features/activities/domain/activity.dart';
import '../features/activities/presentation/activities_screen.dart';
import '../features/activities/presentation/activity_workers_screen.dart';
import '../features/organizations/domain/organization.dart';
import '../features/organizations/domain/project.dart';
import '../features/organizations/domain/site.dart';
import '../features/organizations/presentation/organizations_screen.dart';
import '../features/organizations/presentation/projects_router_screen.dart';
import '../features/organizations/presentation/projects_screen.dart';
import '../features/organizations/presentation/site_workers_screen.dart';
import '../features/organizations/presentation/sites_screen.dart';
import '../features/safety_learning/presentation/my_safety_learning_screen.dart';
import '../features/safety_learning/presentation/safety_learning_library_screen.dart';
import '../features/safety_meeting_points/presentation/my_safety_meeting_points_screen.dart';
import '../features/safety_meeting_points/presentation/safety_meeting_points_screen.dart';
import '../features/daily_safety_meetings/presentation/admin_daily_safety_meetings_screen.dart';
import '../features/daily_safety_meetings/presentation/daily_safety_meetings_router_screen.dart';
import '../features/hazards/presentation/my_hazards_screen.dart';
import '../features/analytics/presentation/analytics_screen.dart';
import '../features/corrective_actions/presentation/corrective_actions_screen.dart';
import '../features/notifications/presentation/notifications_screen.dart';
import '../features/reports/presentation/reports_screen.dart';
import '../features/safety_alerts/presentation/safety_alerts_screen.dart';
import '../features/safety_requirements/presentation/safety_requirements_screen.dart';
import 'app_routes.dart';
import 'app_shell.dart';

/// The routes reachable without a signed-in, approved account. Everything
/// else is operational and requires [AuthStatus.authenticated].
const Set<String> _publicRoutes = {
  AppRoutes.login,
  AppRoutes.register,
};

/// App-wide router configuration.
///
/// Route guarding reads [SessionController.status]:
/// - [AuthStatus.loading]/[AuthStatus.loadingProfile]: show a loading
///   screen while Firebase restores the session / the profile loads.
/// - [AuthStatus.unauthenticated]/[AuthStatus.authenticating]/
///   [AuthStatus.error]: the login or registration screen, whichever the
///   user is on; those screens render the in-flight and error states
///   themselves.
/// - [AuthStatus.pending]: the pending-approval screen.
/// - [AuthStatus.suspended]/[AuthStatus.rejected]/
///   [AuthStatus.profileMissing]: /access-denied, which explains which of
///   the three applies.
/// - [AuthStatus.authenticated]: normal app access.
///
/// An operational route therefore requires BOTH a Firebase user and a loaded
/// profile with `accountStatus == active` — [AuthStatus.authenticated] is
/// the only status that falls through to the shell routes.
///
/// This redirect is a UX convenience only — it prevents showing screens the
/// user has no data for, but the actual authorization boundary is
/// firestore.rules. A modified client that skipped this redirect would
/// still be blocked from reading/writing data by the rules.
///
/// [canReviewPendingAccounts] gates [AppRoutes.pendingApprovals],
/// [AppRoutes.activeUsers] and [AppRoutes.suspendedUsers] — managing
/// already-reviewed users is part of the same review authority as reviewing
/// pending ones. [isPlatformAdministrator] additionally gates
/// [AppRoutes.administration]. A user whose role does not authorize the
/// route is sent to the dashboard exactly as if the route did not exist.
/// This is UX only — the callables behind these screens verify the same role
/// server-side against the caller's stored profile, and Firestore rules deny
/// every client a direct read of another user's document regardless.
///
/// Pure redirect decision, isolated from GoRouterState so it can be unit
/// tested directly. Returns the path to redirect to, or null to allow the
/// current [matchedLocation] to render. Every branch returns null when
/// already at its destination, so no redirect loop is possible.
String? authRedirect(
  AuthStatus status,
  String matchedLocation, {
  bool canReviewPendingAccounts = false,
  bool isPlatformAdministrator = false,
  bool canManageOrgContent = false,
}) {
  final publicRoute = _publicRoutes.contains(matchedLocation);
  final pendingRoute = matchedLocation == AppRoutes.pendingApproval;
  final deniedRoute = matchedLocation == AppRoutes.accessDenied;
  final loadingRoute = matchedLocation == AppRoutes.sessionLoading;
  final reviewRoute = matchedLocation == AppRoutes.pendingApprovals ||
      matchedLocation == AppRoutes.activeUsers ||
      matchedLocation == AppRoutes.suspendedUsers;
  // Org/project/site/activity/worker management — reachable by both `admin`
  // (any organization) and `siteManager` (the organization(s) they manage;
  // enforced server-side, this is UX only). `manageDailySafetyMeetings` is
  // the read-only Administrator meeting list (PROJECT_CONTEXT.md §22A),
  // which `siteManager` may also review. `manageSafetyMeetingPoints` is
  // field-level, per-organization content a Site Manager prepares for their
  // own Foremen (PROJECT_CONTEXT.md §12/§16) — see
  // `safety_meeting_point_callable.ts`'s `requireOrganizationScopedManager`
  // — deliberately NOT grouped with `manageSafetyLearning` below, which
  // stays `admin`-only.
  final administrationRoute = matchedLocation == AppRoutes.administration ||
      matchedLocation == AppRoutes.manageOrganizations ||
      matchedLocation == AppRoutes.manageProjects ||
      matchedLocation == AppRoutes.manageSites ||
      matchedLocation == AppRoutes.manageSiteWorkers ||
      matchedLocation == AppRoutes.manageActivities ||
      matchedLocation == AppRoutes.manageActivityWorkers ||
      matchedLocation == AppRoutes.manageSafetyRequirements ||
      matchedLocation == AppRoutes.manageDailySafetyMeetings ||
      matchedLocation == AppRoutes.manageSafetyMeetingPoints;
  // The company-wide Safety Learning library is a platform-level,
  // `admin`-only responsibility, deliberately NOT delegated to `siteManager`
  // (PROJECT_CONTEXT.md §4, §12).
  final orgContentRoute = matchedLocation == AppRoutes.manageSafetyLearning;

  switch (status) {
    case AuthStatus.loading:
    case AuthStatus.loadingProfile:
      return loadingRoute ? null : AppRoutes.sessionLoading;
    case AuthStatus.unauthenticated:
    case AuthStatus.authenticating:
    case AuthStatus.error:
      // Signed-out users may move freely between login and registration;
      // anything else lands on login.
      return publicRoute ? null : AppRoutes.login;
    case AuthStatus.pending:
      return pendingRoute ? null : AppRoutes.pendingApproval;
    case AuthStatus.suspended:
    case AuthStatus.rejected:
    case AuthStatus.profileMissing:
      return deniedRoute ? null : AppRoutes.accessDenied;
    case AuthStatus.authenticated:
      if (publicRoute || pendingRoute || deniedRoute || loadingRoute) {
        return AppRoutes.dashboard;
      }
      // Role-gated routes. An active user whose role does not authorize one
      // is treated exactly as they would be for any route they cannot
      // reach — sent to the dashboard, told nothing about what exists
      // behind it.
      if (reviewRoute && !canReviewPendingAccounts) {
        return AppRoutes.dashboard;
      }
      if (administrationRoute && !isPlatformAdministrator && !canManageOrgContent) {
        return AppRoutes.dashboard;
      }
      if (orgContentRoute && !isPlatformAdministrator) {
        return AppRoutes.dashboard;
      }
      return null;
  }
}

GoRouter buildAppRouter(SessionController session) {
  return GoRouter(
    initialLocation: AppRoutes.sessionLoading,
    refreshListenable: session,
    redirect: (context, state) => authRedirect(
      session.status,
      state.matchedLocation,
      // A non-Admin's role — including canReviewPendingAccounts/
      // canManageOrgContent — now lives on their active membership, not on
      // UserProfile.platformRole, which is admin-only under the multi-org
      // membership model. profile?.canX defaults to false rather than null,
      // so this must be `||`, not `??`, or the membership check would never
      // be reached.
      canReviewPendingAccounts: (session.profile?.canReviewPendingAccounts ??
              false) ||
          (session.activeMembership?.role.canReviewPendingAccounts ?? false),
      isPlatformAdministrator:
          session.profile?.isPlatformAdministrator ?? false,
      canManageOrgContent:
          (session.profile?.canManageOrgContent ?? false) ||
              (session.activeMembership?.role.canManageOrgContent ?? false),
    ),
    routes: [
      GoRoute(
        path: AppRoutes.sessionLoading,
        builder: (context, state) => const SessionLoadingScreen(),
      ),
      GoRoute(
        path: AppRoutes.login,
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: AppRoutes.register,
        builder: (context, state) => const RegisterScreen(),
      ),
      GoRoute(
        path: AppRoutes.pendingApproval,
        builder: (context, state) => const PendingApprovalScreen(),
      ),
      GoRoute(
        path: AppRoutes.accessDenied,
        builder: (context, state) => const AccessDeniedScreen(),
      ),
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(
            path: AppRoutes.dashboard,
            builder: (context, state) => const PlaceholderScreen(
              featureName: 'Dashboard',
              icon: Icons.dashboard_outlined,
            ),
          ),
          GoRoute(
            path: AppRoutes.pendingApprovals,
            builder: (context, state) => const PendingApprovalsScreen(),
          ),
          GoRoute(
            path: AppRoutes.activeUsers,
            builder: (context, state) => const OrganizationUsersScreen(
              statuses: [AccountStatus.active],
              title: 'Active Users',
            ),
          ),
          GoRoute(
            path: AppRoutes.suspendedUsers,
            builder: (context, state) => const OrganizationUsersScreen(
              statuses: [AccountStatus.suspended, AccountStatus.rejected],
              title: 'Suspended / Rejected Users',
            ),
          ),
          GoRoute(
            path: AppRoutes.workers,
            builder: (context, state) => const PlaceholderScreen(
              featureName: 'Workers',
              icon: Icons.groups_outlined,
            ),
          ),
          GoRoute(
            path: AppRoutes.projects,
            builder: (context, state) => const ProjectsRouterScreen(),
          ),
          GoRoute(
            path: AppRoutes.sites,
            builder: (context, state) => const PlaceholderScreen(
              featureName: 'Sites',
              icon: Icons.location_city_outlined,
            ),
          ),
          GoRoute(
            path: AppRoutes.activities,
            builder: (context, state) => const PlaceholderScreen(
              featureName: 'Activities',
              icon: Icons.engineering_outlined,
            ),
          ),
          GoRoute(
            path: AppRoutes.safetyLearning,
            builder: (context, state) => const MySafetyLearningScreen(),
          ),
          GoRoute(
            path: AppRoutes.safetyVideos,
            builder: (context, state) => const PlaceholderScreen(
              featureName: 'Safety Videos',
              icon: Icons.play_circle_outline,
            ),
          ),
          GoRoute(
            path: AppRoutes.safetyMeetingPoints,
            builder: (context, state) => const MySafetyMeetingPointsScreen(),
          ),
          GoRoute(
            path: AppRoutes.dailySafetyMeetings,
            builder: (context, state) => const DailySafetyMeetingsRouterScreen(),
          ),
          GoRoute(
            path: AppRoutes.hazards,
            builder: (context, state) => const MyHazardsScreen(),
          ),
          GoRoute(
            path: AppRoutes.correctiveActions,
            builder: (context, state) => const CorrectiveActionsScreen(),
          ),
          GoRoute(
            path: AppRoutes.safetyAlerts,
            builder: (context, state) => const SafetyAlertsScreen(),
          ),
          GoRoute(
            path: AppRoutes.notifications,
            builder: (context, state) => const NotificationsScreen(),
          ),
          GoRoute(
            path: AppRoutes.reports,
            builder: (context, state) => const ReportsScreen(),
          ),
          GoRoute(
            path: AppRoutes.analytics,
            builder: (context, state) => const AnalyticsScreen(),
          ),
          GoRoute(
            path: AppRoutes.administration,
            builder: (context, state) => const AdministrationScreen(),
          ),
          GoRoute(
            path: AppRoutes.manageOrganizations,
            builder: (context, state) => const OrganizationsScreen(),
          ),
          GoRoute(
            path: AppRoutes.manageProjects,
            // Reached only via a Card tap on OrganizationsScreen, which
            // always supplies the tapped Organization as `extra`. Typing
            // this URL directly (or refreshing on it) loses that context —
            // there is nothing to fall back to but the Organizations list.
            builder: (context, state) {
              final organization = state.extra;
              if (organization is! Organization) {
                return const OrganizationsScreen();
              }
              return ProjectsScreen(organization: organization);
            },
          ),
          GoRoute(
            path: AppRoutes.manageSites,
            // Reached only via a Card tap on ProjectsScreen, which supplies
            // the (organization, project) pair as `extra`. Same fallback
            // reasoning as manageProjects above.
            builder: (context, state) {
              final extra = state.extra;
              if (extra is! ({Organization organization, Project project})) {
                return const OrganizationsScreen();
              }
              return SitesScreen(
                organization: extra.organization,
                project: extra.project,
              );
            },
          ),
          GoRoute(
            path: AppRoutes.manageActivities,
            // Reached only via a Card tap on SitesScreen, which supplies
            // the (organization, project, site) triple as `extra`. Same
            // fallback reasoning as manageSites above.
            builder: (context, state) {
              final extra = state.extra;
              if (extra
                  is! ({
                    Organization organization,
                    Project project,
                    Site site,
                  })) {
                return const OrganizationsScreen();
              }
              return ActivitiesScreen(
                organization: extra.organization,
                project: extra.project,
                site: extra.site,
              );
            },
          ),
          GoRoute(
            path: AppRoutes.manageActivityWorkers,
            // Reached only via a Card tap on ActivitiesScreen, which
            // supplies the (organization, project, site, activity) 4-tuple
            // as `extra`. Same fallback reasoning as manageSites above.
            builder: (context, state) {
              final extra = state.extra;
              if (extra
                  is! ({
                    Organization organization,
                    Project project,
                    Site site,
                    Activity activity,
                  })) {
                return const OrganizationsScreen();
              }
              return ActivityWorkersScreen(
                organization: extra.organization,
                project: extra.project,
                site: extra.site,
                activity: extra.activity,
              );
            },
          ),
          GoRoute(
            path: AppRoutes.manageSiteWorkers,
            // Reached only via a Card tap on SitesScreen, which supplies
            // the (organization, project, site) triple as `extra` — the same
            // shape manageActivities uses. Same fallback reasoning as
            // manageSites above.
            builder: (context, state) {
              final extra = state.extra;
              if (extra
                  is! ({
                    Organization organization,
                    Project project,
                    Site site,
                  })) {
                return const OrganizationsScreen();
              }
              return SiteWorkersScreen(
                organization: extra.organization,
                project: extra.project,
                site: extra.site,
              );
            },
          ),
          GoRoute(
            path: AppRoutes.manageSafetyLearning,
            // Reached only via a Card tap on AdministrationScreen, which
            // supplies the tapped Organization as `extra` (the acting
            // admin's own organization for an organizationAdministrator, or
            // a System Administrator's chosen organization). Same fallback
            // reasoning as manageProjects above.
            builder: (context, state) {
              final organization = state.extra;
              if (organization is! Organization) {
                return const OrganizationsScreen();
              }
              return SafetyLearningLibraryScreen(
                organizationId: organization.id,
              );
            },
          ),
          GoRoute(
            path: AppRoutes.manageSafetyRequirements,
            // Same `extra` contract as manageSafetyLearning above.
            builder: (context, state) {
              final organization = state.extra;
              if (organization is! Organization) {
                return const OrganizationsScreen();
              }
              return SafetyRequirementsScreen(organization: organization);
            },
          ),
          GoRoute(
            path: AppRoutes.manageSafetyMeetingPoints,
            // Reachable two ways, unlike manageSafetyLearning above: via
            // OrganizationsScreen's drill-down (`extra` carries the tapped
            // Organization), or directly from the sidebar's "Safety Meeting
            // Points" entry (no `extra` at all) — SafetyMeetingPointsScreen
            // already falls back to the signed-in user's own
            // activeOrganizationId when `organizationId` is omitted, so
            // there is no OrganizationsScreen fallback needed here the way
            // manageProjects (pre-ProjectsRouterScreen) needed one.
            builder: (context, state) {
              final organization = state.extra;
              return SafetyMeetingPointsScreen(
                organizationId:
                    organization is Organization ? organization.id : null,
              );
            },
          ),
          GoRoute(
            path: AppRoutes.manageDailySafetyMeetings,
            // Same `extra` contract as manageSafetyLearning above.
            builder: (context, state) {
              final organization = state.extra;
              if (organization is! Organization) {
                return const OrganizationsScreen();
              }
              return AdminDailySafetyMeetingsScreen(organization: organization);
            },
          ),
        ],
      ),
    ],
  );
}

/// Convenience accessor used by [main.dart] to build the router with the
/// session controller from Provider context.
GoRouter appRouterFrom(BuildContext context) {
  return buildAppRouter(context.read<SessionController>());
}
