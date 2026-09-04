/// The platform authorization role model (PROJECT_CONTEXT.md §12–19).
///
/// JVA Safety uses exactly four platform authorization roles, stored on
/// [UserProfile.platformRole] (Firestore field `platformRole`). The type
/// itself keeps the name `AppRole` for historical/call-site continuity —
/// only the *field* it is stored in was renamed from `role` to
/// `platformRole` — but every value and capability below reflects the new
/// 4-role model, not the old 7-role one.
///
/// This is a migration down from an earlier 7-value model
/// (`systemAdministrator` / `organizationAdministrator` / `safetyManager` /
/// `siteSuperintendent` / `siteSupervisor` / `foreman` / `worker`). The
/// mapping:
///
///  - `systemAdministrator` -> [admin]
///  - `organizationAdministrator` -> split: org-creation and
///    project/site/activity/Foreman management moved to [siteManager];
///    Safety Learning library, Safety Meeting Point library management and
///    org-wide oversight moved to [admin]
///  - `safetyManager` -> folded into [siteManager]
///  - `siteSuperintendent` -> [siteManager]
///  - `siteSupervisor` -> merged into [foreman]
///  - `foreman` -> [foreman] (unchanged)
///  - `worker` -> [worker] (unchanged)
///
/// A role grants authority only within the holder's own organization(s) —
/// [admin] is the sole platform-level exception (PROJECT_CONTEXT.md §12,
/// §18): it exists so the very first account on a fresh deployment can
/// operate before any organization exists to scope it to. It is never
/// reachable through registration or through the in-app review flow — see
/// `functions/src/scripts/approve_account.ts`'s `bootstrap-admin` command,
/// the only path that can grant it, gated on possession of service-account
/// credentials rather than any in-app authorization.
///
/// [worker] has no approval or assignment authority at all over other
/// accounts. [foreman] approves/manages [worker] accounts within their own
/// assigned site(s) only.
enum AppRole {
  admin,
  siteManager,
  foreman,
  worker;

  /// The value stored in the Firestore `platformRole` field.
  String get id => name;

  String get label => switch (this) {
    AppRole.admin => 'Admin',
    AppRole.siteManager => 'Site Manager / Site Superintendent',
    AppRole.foreman => 'Foreman / Site Supervisor',
    AppRole.worker => 'Worker',
  };

  /// Whether this role may review pending accounts (approve/reject) and
  /// assign an organization, role and worker type.
  ///
  /// [foreman] is included here — unlike the old model's excluded
  /// `siteSupervisor` — because §16 now grants Foreman approval authority
  /// over Workers on their own assigned site(s), and site assignment exists
  /// as a concept in the data model. The callables scope this further to
  /// "within the caller's own site(s)/organization(s)"; this flag only says
  /// the role family is capable of reviewing at all.
  bool get canReviewPendingAccounts => switch (this) {
    AppRole.admin => true,
    AppRole.siteManager => true,
    AppRole.foreman => true,
    AppRole.worker => false,
  };

  /// Whether this role has platform-wide authority not scoped to any single
  /// organization — only [admin].
  bool get isPlatformLevel => this == AppRole.admin;

  /// Whether this role may review completed Daily Safety Meetings
  /// organization-wide (`AdminDailySafetyMeetingsScreen`) — a read-only
  /// authority, distinct from [canReviewPendingAccounts].
  ///
  /// DECISION: [foreman] is deliberately **excluded** here, even though the
  /// old model's merged-in `siteSupervisor` value had this flag. Per
  /// PROJECT_CONTEXT.md §16/§21/§22A, the Foreman's role with respect to
  /// Daily Safety Meetings is to **conduct and record** them in their own
  /// Meeting Workspace, not to review other Foremen's meetings in the
  /// read-only Administrator meeting list — that reviewing capacity belongs
  /// to [siteManager] and [admin] only ("Reviewed by: Site Manager / Site
  /// Superintendent, Admin" — §22A). A Foreman already sees their own
  /// meeting history through the Meeting Workspace, which does not use this
  /// flag.
  bool get canReviewDailySafetyMeetings => switch (this) {
    AppRole.admin => true,
    AppRole.siteManager => true,
    AppRole.foreman => false,
    AppRole.worker => false,
  };

  /// Whether this role may assign [AppRole] values to other users.
  ///
  /// Same grant as [canReviewPendingAccounts]: the two are exercised
  /// together at review time (an approver assigns organization, role and
  /// worker type in one action), so they share one authority boundary today.
  bool get canAssignRole => canReviewPendingAccounts;

  /// Only privileged roles may be granted through account review — a Worker
  /// is a legitimate assignment outcome, but cannot *be* the reviewer, and
  /// this app never lets a target choose its own role.
  bool get isAuthorizedReviewerRole => canReviewPendingAccounts;

  /// Whether this role may create a new organization, becoming its
  /// operational manager (PROJECT_CONTEXT.md §12, "Organization Hierarchy").
  /// [admin] may also create organizations as part of platform-level
  /// administration.
  bool get canCreateOrganization => switch (this) {
    AppRole.admin => true,
    AppRole.siteManager => true,
    AppRole.foreman => false,
    AppRole.worker => false,
  };

  /// Whether this role manages the company-wide Safety Learning library —
  /// [admin] only; deliberately not delegated to [siteManager]
  /// (PROJECT_CONTEXT.md §4, §12).
  bool get canManageSafetyLearningLibrary => this == AppRole.admin;

  /// Whether this role manages the company-wide Safety Meeting Point
  /// library — [admin] only; deliberately not delegated to [siteManager]
  /// (PROJECT_CONTEXT.md §4).
  bool get canManageSafetyMeetingPointLibrary => this == AppRole.admin;

  /// Whether this role may approve/manage Foreman accounts within the
  /// organization(s) it manages (PROJECT_CONTEXT.md §16).
  bool get canApproveForemen => switch (this) {
    AppRole.admin => true,
    AppRole.siteManager => true,
    AppRole.foreman => false,
    AppRole.worker => false,
  };

  /// Whether this role may approve/register Worker accounts within its own
  /// assigned site(s) (PROJECT_CONTEXT.md §16).
  bool get canApproveWorkers => switch (this) {
    AppRole.admin => true,
    AppRole.siteManager => true,
    AppRole.foreman => true,
    AppRole.worker => false,
  };

  /// Whether this role may manage projects/sites/activities and the
  /// workforce for the organization(s) it manages — [siteManager] and
  /// [admin] (PROJECT_CONTEXT.md §12).
  bool get canManageOrgContent => switch (this) {
    AppRole.admin => true,
    AppRole.siteManager => true,
    AppRole.foreman => false,
    AppRole.worker => false,
  };

  /// Parses a stored value, returning null when [id] is unrecognised.
  ///
  /// Never throws: unlike [AccountStatus], a malformed role must fail closed
  /// by granting nothing, not by denying the whole profile.
  static AppRole? tryFromId(String? id) {
    if (id == null) return null;
    for (final role in AppRole.values) {
      if (role.id == id) return role;
    }
    return null;
  }
}
