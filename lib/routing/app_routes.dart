/// Named route paths for the app. Kept as plain string constants so
/// go_router config and any `context.go(...)` calls stay typo-safe.
class AppRoutes {
  AppRoutes._();

  static const String sessionLoading = '/session-loading';
  static const String login = '/login';
  static const String register = '/register';

  /// Where a self-registered user waits until an approver acts on their
  /// account.
  static const String pendingApproval = '/pending-approval';
  static const String accessDenied = '/access-denied';

  /// The approval inbox, reachable only by a user whose role authorizes
  /// reviewing pending accounts. Note this is an *operational* route: it
  /// also requires an active account, like everything else in the shell.
  static const String pendingApprovals = '/pending-approvals';

  /// The Active Users list, gated the same as [pendingApprovals]: any role
  /// that may review pending accounts may also manage already-reviewed ones.
  static const String activeUsers = '/active-users';

  /// The Suspended/Rejected Users list, gated the same as [pendingApprovals].
  static const String suspendedUsers = '/suspended-users';

  /// The Organizations screen: an Admin sees and manages every organization;
  /// an [AppRole.siteManager] sees only their own — see
  /// [OrganizationsScreen]'s `canManage`/`isPlatformAdministrator` getters.
  static const String manageOrganizations = '/administration/organizations';

  /// The Projects screen for one organization. Reachable by Admin (any
  /// organization) or [AppRole.siteManager] (the organization(s) they
  /// manage) — see [ProjectsScreen]'s `canManage` getter.
  static const String manageProjects = '/administration/projects';

  /// The Sites screen for one organization. Reachable the same as
  /// [manageProjects] — see [SitesScreen]'s `canManage` getter.
  /// [manageSiteWorkers] is where a Site Manager's actual write authority
  /// over a site (worker assignment) is exposed.
  static const String manageSites = '/administration/sites';

  /// The Activities management screen for one site. Gated the same as
  /// [manageProjects] — see [ActivitiesScreen]'s `canManage` getter.
  static const String manageActivities = '/administration/activities';

  /// The worker-assignment screen for one activity. Gated the same as
  /// [manageActivities].
  static const String manageActivityWorkers =
      '/administration/activities/workers';

  /// The worker-assignment screen for one site. Reachable by Admin (any
  /// organization) or [AppRole.siteManager] (the organization(s) they
  /// manage) — see [SiteWorkersScreen]'s `canManage` getter. This is where
  /// `assignWorkerToSite`/`removeWorkerFromSite` are actually exposed in the
  /// UI.
  static const String manageSiteWorkers = '/administration/sites/workers';

  /// The Safety Learning library management screen. Gated on
  /// [SessionController.isPlatformAdministrator] alone — the company-wide
  /// Safety Learning library is an `admin`-only responsibility, deliberately
  /// not delegated to `siteManager` (PROJECT_CONTEXT.md §4, §12; see
  /// [SafetyLearningLibraryScreen]'s `canManage` getter, which checks
  /// `canManageSafetyLearningLibrary`).
  static const String manageSafetyLearning = '/administration/safety-learning';

  /// The Safety Requirements management screen. Gated the same as
  /// [manageSafetyLearning].
  static const String manageSafetyRequirements =
      '/administration/safety-requirements';

  /// The Safety Meeting Points management screen. Reachable by Admin (any
  /// organization) or an [AppRole.siteManager] of the matching organization
  /// — field-level content a Site Manager prepares for their own Foremen
  /// (PROJECT_CONTEXT.md §12/§16), NOT the same `admin`-only shape as
  /// [manageSafetyLearning] — see [SafetyMeetingPointsScreen]'s `canManage`
  /// getter.
  static const String manageSafetyMeetingPoints =
      '/administration/safety-meeting-points';

  /// The administrator-facing Daily Safety Meetings list for one
  /// organization — a review/history function, not the foreman's
  /// operational meeting workspace ([AppRoutes.dailySafetyMeetings]). Gated
  /// the same as [manageSafetyMeetingPoints]; see
  /// [AdminDailySafetyMeetingsScreen]'s `canManage` getter.
  ///
  /// This is a System Administrator's path to an *other* organization's
  /// meetings (via the Organizations drill-down); a reviewer viewing their
  /// own organization's meetings reaches the same screen through
  /// [dailySafetyMeetings] instead, which dispatches by role — see
  /// [DailySafetyMeetingsRouterScreen].
  static const String manageDailySafetyMeetings =
      '/administration/daily-safety-meetings';

  static const String dashboard = '/dashboard';

  /// A Foreman's read-only view of the Workers assigned to their own
  /// site(s) — see [MyWorkersScreen]. Not route-gated beyond the
  /// authenticated-user redirect: the screen itself is a no-op for any
  /// role other than a site-assigned Foreman, matching the pattern used by
  /// [DailySafetyMeetingScreen]/[DailySafetyMeetingsRouterScreen].
  static const String workers = '/workers';

  /// The sidebar's own "Projects" destination — resolves the signed-in
  /// user's active organization directly and shows [ProjectsScreen] for it
  /// (see [ProjectsRouterScreen]), reachable without first navigating
  /// through Organizations. Distinct from [manageProjects], which requires
  /// an [Organization] passed via route `extra` from
  /// [OrganizationsScreen]'s own drill-down (still the only path to Sites
  /// and Activities, which need a project/site chosen first).
  static const String projects = '/projects';
  static const String sites = '/sites';
  static const String activities = '/activities';
  static const String safetyLearning = '/safety-learning';
  static const String safetyMeetingPoints = '/safety-meeting-points';

  /// Placeholder — no screen exists yet. Included in the sidebar per the
  /// navigation redesign's "Meetings & Learning" group so the information
  /// architecture is visible ahead of the feature shipping.
  static const String safetyVideos = '/safety-videos';

  /// The bottom-nav "Meetings" destination — dispatches by role via
  /// [DailySafetyMeetingsRouterScreen]: the foreman's own operational
  /// workspace, or the read-only organization-wide review screen for any
  /// other role [AppRole.canReviewDailySafetyMeetings] grants.
  static const String dailySafetyMeetings = '/daily-safety-meetings';
  static const String hazards = '/hazards';
  static const String correctiveActions = '/corrective-actions';
  static const String safetyAlerts = '/safety-alerts';
  static const String notifications = '/notifications';
  static const String reports = '/reports';
  static const String analytics = '/analytics';
  static const String administration = '/administration';
}
