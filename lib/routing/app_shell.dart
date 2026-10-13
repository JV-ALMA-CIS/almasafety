import 'package:flutter/material.dart';
import '../core/widgets/live_stream_builder.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../core/services/firestore_service.dart';
import '../core/services/session_controller.dart';
import '../core/services/theme_controller.dart';
import '../core/theme/app_colors.dart';
import '../core/widgets/dashboard_header.dart';
import '../core/widgets/responsive_scaffold.dart';
import '../features/authentication/domain/app_role.dart';
import '../features/daily_safety_meetings/presentation/daily_safety_meeting_history_screen.dart';
import '../features/notifications/data/notification_repository.dart';
import '../features/notifications/domain/app_notification.dart';
import 'app_routes.dart';

/// Wraps the currently routed screen with the responsive navigation shell.
///
/// Global navigation lives in a single grouped sidebar/drawer
/// ([ResponsiveScaffold]'s sectioned mode) rather than scattered across the
/// app bar — see [_sectionsFor], which is the one place role-aware
/// visibility is decided, built from the same [AppRole] capability getters
/// (`canReviewPendingAccounts`, `canManageOrgContent`,
/// `canReviewDailySafetyMeetings`, `canManageSafetyLearningLibrary`,
/// `canManageSafetyMeetingPointLibrary`) every other role check in this app
/// already uses. This is UX only — hiding an item here changes nothing
/// about what the router/rules/callables would allow a modified client to
/// reach; see those layers for the actual enforcement.
///
/// PHASE 1 (single-company model): the sidebar header carries the app's own
/// "JVA Safety" branding — no organization switcher. JV ALMA CIS is the
/// one company every user works under; there is nothing to switch between,
/// so surfacing a picker (even a static "which org am I in" label) would
/// invite a question that no longer has a meaningful answer. Internally,
/// `SessionController.activeOrganizationId` still resolves to that one
/// company's Firestore id — nothing about the underlying membership model
/// changed, only what the UI shows. The app bar itself carries no title of
/// its own (the sidebar already names the app) — just a drawer toggle where
/// needed and the global actions (Meeting History where relevant,
/// Notifications, Appearance, Sign Out).
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).uri.toString();
    final sessionController = context.watch<SessionController>();
    final profile = sessionController.profile;
    final isPlatformAdministrator = profile?.isPlatformAdministrator ?? false;
    // A non-Admin's role now lives on their active Membership, not on the
    // profile's (now admin-only) platformRole — except for the one
    // transient case of a Site Manager just approved with no organization
    // yet, signalled instead by profile.platformRole == siteManager (see
    // account_approval.ts's approveAccount). Both must be checked, or that
    // Site Manager loses every nav entry that would let them reach the one
    // screen (Organizations) that gives them their first membership.
    final membershipRole = sessionController.activeMembership?.role;
    final isTransientSiteManager = profile?.platformRole == AppRole.siteManager;
    final canReviewPendingAccounts =
        isPlatformAdministrator ||
        (membershipRole?.canReviewPendingAccounts ?? false) ||
        isTransientSiteManager;
    final canManageOrgContent =
        isPlatformAdministrator ||
        (membershipRole?.canManageOrgContent ?? false) ||
        isTransientSiteManager;
    final canReviewDailySafetyMeetings =
        isPlatformAdministrator ||
        (membershipRole?.canReviewDailySafetyMeetings ?? false);
    final canManageSafetyLearningLibrary =
        profile?.canManageSafetyLearningLibrary ?? false;

    final sections = _sectionsFor(
      isPlatformAdministrator: isPlatformAdministrator,
      canReviewPendingAccounts: canReviewPendingAccounts,
      canManageOrgContent: canManageOrgContent,
      canReviewDailySafetyMeetings: canReviewDailySafetyMeetings,
      canManageSafetyLearningLibrary: canManageSafetyLearningLibrary,
      isForeman: membershipRole == AppRole.foreman,
    );

    return ResponsiveScaffold(
      header: _SidebarHeader(
        userName: profile?.name,
        role: isPlatformAdministrator
            ? AppRole.admin
            : membershipRole ?? profile?.platformRole,
      ),
      sections: sections,
      currentRoute: location,
      onNavSelected: (route) => context.go(route),
      actions: [
        // A Foreman's own Meeting History — the entry point to find and
        // resume a forgotten in-progress meeting (see
        // DailySafetyMeetingScreen.resumeMeetingId's doc comment) — used to
        // live as a button at the bottom of the meeting workspace's own
        // scrollable content, easy to miss exactly when it mattered most
        // (a Foreman who forgot to complete a meeting also isn't likely to
        // go looking for a buried button). Shown here in the app bar
        // instead: always visible the moment a Foreman opens Daily Safety
        // Meetings, no scrolling required. Scoped to the exact route AND
        // role a Foreman actually sees — [AppRoutes.dailySafetyMeetings]
        // also serves [AdminDailySafetyMeetingsScreen] to a Site Manager,
        // which has no foreman-workspace history concept to jump to.
        if (location == AppRoutes.dailySafetyMeetings &&
            membershipRole == AppRole.foreman &&
            sessionController.activeOrganizationId != null)
          IconButton(
            tooltip: 'Meeting History',
            icon: const Icon(Icons.history_outlined),
            onPressed: () => Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute<void>(
                builder: (_) => DailySafetyMeetingHistoryScreen(
                  organizationId: sessionController.activeOrganizationId!,
                ),
              ),
            ),
          ),
        if (sessionController.activeOrganizationId != null &&
            profile?.uid != null)
          _NotificationBellAction(
            organizationId: sessionController.activeOrganizationId!,
            uid: profile!.uid,
          ),
        // Lets a user override the app's light/dark appearance in-app,
        // independent of their device's own OS/browser setting — see
        // ThemeController's doc comment for why this exists (desktop
        // Firefox in particular does not forward its own "Theme" setting
        // to prefers-color-scheme, only the OS-wide setting does, so users
        // sharing one device with varying OS themes had no in-app way to
        // pick dark mode for just this app).
        const _ThemeModeAction(),
        // The only way out of a signed-in session anywhere in the normal
        // app shell — previously `SessionController.signOut` was reachable
        // only from the pending-approval/access-denied screens, so a
        // successfully signed-in user (e.g. testing multiple accounts in
        // the same browser) had no way to switch accounts short of clearing
        // browser storage. Always shown, regardless of role/organization.
        IconButton(
          tooltip: 'Sign Out',
          icon: const Icon(Icons.logout_outlined),
          onPressed: () => sessionController.signOut(),
        ),
      ],
      body: child,
    );
  }

  /// The one place nav visibility per role is decided. Every entry maps to
  /// an existing route; see AppRoutes for what each one requires.
  ///
  /// - **Dashboard** — everyone.
  /// - **Operations** (Projects) — anyone who can act on organization
  ///   content (Admin, Site Manager) or review daily safety meetings
  ///   (which also implies organization-scoped standing); a Foreman/Worker
  ///   has no Projects screen to manage, so this section is omitted for
  ///   them entirely rather than shown empty.
  /// - **Safety** — every operational role (Admin, Site Manager, Foreman,
  ///   Worker all have a stake in hazards/corrective actions/alerts) — the
  ///   underlying screens themselves already narrow by role/site, exactly
  ///   like today.
  /// - **Meetings & Learning** — everyone.
  /// - **Insights** (Analytics, Reports) — organization-wide oversight
  ///   roles only (Admin, Site Manager), gated on `canManageOrgContent`
  ///   rather than `canReviewPendingAccounts` — a Foreman also satisfies
  ///   `canReviewPendingAccounts` (they may approve Workers), but has no
  ///   organization-wide analytics/reporting standing per
  ///   PROJECT_CONTEXT.md §12/§16; conflating the two would show a Foreman
  ///   Insights they cannot actually use.
  /// - **Administration** — reviewer roles only (`canReviewPendingAccounts`
  ///   — Admin, Site Manager and Foreman all have SOME review authority),
  ///   but its ENTRIES differ by role: the "Administration" landing page
  ///   (PHASE 1: Active/Suspended Users only — its former "Organizations"
  ///   entry is gone under the single-company model, see
  ///   [AdministrationScreen]) additionally requires `canManageOrgContent`,
  ///   which a Foreman does not hold, so they see Pending Approvals and My
  ///   Workers instead — never a dead-end entry that `AdministrationScreen`
  ///   itself would refuse.
  List<NavSection> _sectionsFor({
    required bool isPlatformAdministrator,
    required bool canReviewPendingAccounts,
    required bool canManageOrgContent,
    required bool canReviewDailySafetyMeetings,
    required bool canManageSafetyLearningLibrary,
    required bool isForeman,
  }) {
    final showOperations = canManageOrgContent || canReviewDailySafetyMeetings;
    final showInsights = canManageOrgContent;

    return [
      const NavSection(
        entries: [
          NavSectionEntry(
            icon: Icons.dashboard_outlined,
            selectedIcon: Icons.dashboard,
            label: 'Dashboard',
            route: AppRoutes.dashboard,
            color: AppColors.dashboard,
          ),
        ],
      ),
      if (showOperations)
        const NavSection(
          title: 'Operations',
          entries: [
            NavSectionEntry(
              icon: Icons.apartment_outlined,
              selectedIcon: Icons.apartment,
              label: 'Projects',
              route: AppRoutes.projects,
              color: AppColors.projects,
            ),
          ],
        ),
      NavSection(
        title: 'Safety',
        entries: [
          // First in Safety: the one way in for anything wrong on site.
          const NavSectionEntry(
            icon: Icons.campaign_outlined,
            selectedIcon: Icons.campaign,
            label: 'Report a Safety Issue',
            route: AppRoutes.reportSafetyIssue,
            color: AppColors.stop,
          ),
          const NavSectionEntry(
            icon: Icons.warning_amber_outlined,
            selectedIcon: Icons.warning_amber,
            label: 'Hazards',
            route: AppRoutes.hazards,
            color: AppColors.hazards,
          ),
          const NavSectionEntry(
            icon: Icons.personal_injury_outlined,
            selectedIcon: Icons.personal_injury,
            label: 'Incidents',
            route: AppRoutes.incidents,
            color: AppColors.stop,
          ),
          // Daily site inspections / weekly HSE walk-downs — carried out by
          // Foremen and Site Managers (Safety Plan, Section 7).
          if (canReviewPendingAccounts)
            const NavSectionEntry(
              icon: Icons.fact_check_outlined,
              selectedIcon: Icons.fact_check,
              label: 'Inspections',
              route: AppRoutes.inspections,
              color: AppColors.inspections,
            ),
          const NavSectionEntry(
            icon: Icons.build_outlined,
            selectedIcon: Icons.build,
            label: 'Corrective Actions',
            route: AppRoutes.correctiveActions,
            color: AppColors.correctiveActions,
          ),
          const NavSectionEntry(
            icon: Icons.campaign_outlined,
            selectedIcon: Icons.campaign,
            label: 'Safety Alerts',
            route: AppRoutes.safetyAlerts,
            color: AppColors.safetyAlerts,
          ),
        ],
      ),
      NavSection(
        title: 'Meetings & Learning',
        entries: [
          const NavSectionEntry(
            icon: Icons.fact_check_outlined,
            selectedIcon: Icons.fact_check,
            label: 'Daily Safety Meetings',
            route: AppRoutes.dailySafetyMeetings,
            color: AppColors.meetings,
          ),
          // "Safety Learning" here is the signed-in user's OWN required
          // learning (MySafetyLearningScreen) — meaningful for a Foreman or
          // Worker, who each have personal WorkerLearningRecord documents.
          // A Site Manager/Admin has none: they review learning org-wide
          // through "Learning Compliance" under Insights instead, so
          // showing them this entry only led to the confusing "No safety
          // learning is currently required of you" message for a role that
          // was never meant to have any. Gated on the same
          // canReviewDailySafetyMeetings flag Daily Safety Meetings itself
          // uses to tell a reviewer role apart from a Foreman.
          if (!canReviewDailySafetyMeetings)
            const NavSectionEntry(
              icon: Icons.school_outlined,
              selectedIcon: Icons.school,
              label: 'Safety Learning',
              route: AppRoutes.safetyLearning,
              color: AppColors.learning,
            ),
          const NavSectionEntry(
            icon: Icons.play_circle_outline,
            selectedIcon: Icons.play_circle,
            label: 'Safety Videos',
            route: AppRoutes.safetyVideos,
            color: AppColors.videos,
          ),
          // A Foreman's own crew readiness check — same screen Admin/Site
          // Manager use under Insights ("Learning Compliance"), scoped down
          // to the Foreman's own site(s) — see
          // SafetyLearningComplianceScreen's own doc comment for why. Lives
          // here rather than under Insights (which stays hidden for a
          // Foreman — see that section's own doc note) since this is a
          // meeting-readiness check, not organization-wide oversight.
          if (isForeman)
            const NavSectionEntry(
              icon: Icons.verified_user_outlined,
              selectedIcon: Icons.verified_user,
              label: 'Crew Compliance',
              route: AppRoutes.safetyLearningCompliance,
              color: AppColors.compliance,
            ),
        ],
      ),
      if (showInsights)
        const NavSection(
          title: 'Insights',
          entries: [
            NavSectionEntry(
              icon: Icons.bar_chart_outlined,
              selectedIcon: Icons.bar_chart,
              label: 'Analytics',
              route: AppRoutes.analytics,
              color: AppColors.analytics,
            ),
            NavSectionEntry(
              icon: Icons.summarize_outlined,
              selectedIcon: Icons.summarize,
              label: 'Reports',
              route: AppRoutes.reports,
              color: AppColors.reports,
            ),
            NavSectionEntry(
              icon: Icons.verified_user_outlined,
              selectedIcon: Icons.verified_user,
              label: 'Learning Compliance',
              route: AppRoutes.safetyLearningCompliance,
              color: AppColors.compliance,
            ),
          ],
        ),
      if (canReviewPendingAccounts)
        NavSection(
          title: 'Administration',
          entries: [
            // AdministrationScreen's own landing page (Active/Suspended
            // Users, Organizations) is gated on canManageOrgContent, not
            // canReviewPendingAccounts — a Foreman satisfies the latter
            // (they may approve Workers) but not the former (no
            // organization-wide management standing per
            // PROJECT_CONTEXT.md §16), so showing them this entry would be
            // a dead end ("you do not have permission"). A Foreman's own
            // review authority is fully covered by Pending Approvals and
            // My Workers below instead.
            if (canManageOrgContent)
              const NavSectionEntry(
                icon: Icons.admin_panel_settings_outlined,
                selectedIcon: Icons.admin_panel_settings,
                label: 'Administration',
                route: AppRoutes.administration,
                color: AppColors.administration,
              ),
            const NavSectionEntry(
              icon: Icons.how_to_reg_outlined,
              selectedIcon: Icons.how_to_reg,
              label: 'Pending Approvals',
              route: AppRoutes.pendingApprovals,
              color: AppColors.people,
            ),
            // My Workers is the Foreman-scoped counterpart to Site
            // Manager/Admin's Organizations -> Site Workers drill-down:
            // a read-only list of the Workers assigned to the Foreman's
            // own site(s). Shown only to a Foreman (review authority
            // without org-content management) — a Site Manager/Admin
            // already sees every site's assigned workers through
            // Organizations instead.
            if (canReviewPendingAccounts && !canManageOrgContent)
              const NavSectionEntry(
                icon: Icons.groups_outlined,
                selectedIcon: Icons.groups,
                label: 'My Workers',
                route: AppRoutes.workers,
                color: AppColors.people,
              ),
            // The company-wide Safety Learning library is admin-only,
            // deliberately not delegated to Site Manager (PROJECT_CONTEXT.md
            // §4, §12) — see AppRole.canManageSafetyLearningLibrary.
            if (canManageSafetyLearningLibrary)
              const NavSectionEntry(
                icon: Icons.library_books_outlined,
                selectedIcon: Icons.library_books,
                label: 'Safety Learning Library',
                route: AppRoutes.manageSafetyLearning,
                color: AppColors.learning,
              ),
            // Safety Requirements decides WHICH of the library's learning
            // items are actually required (for which site/activity, or
            // organization-wide) — org-content authoring, same
            // canManageOrgContent boundary as Safety Meeting Points below,
            // not the admin-only library gate: a Site Manager sets
            // requirements for their own organization even though only an
            // Admin curates the shared learning library those requirements
            // draw from.
            if (canManageOrgContent)
              const NavSectionEntry(
                icon: Icons.checklist_outlined,
                selectedIcon: Icons.checklist,
                label: 'Safety Requirements',
                route: AppRoutes.manageSafetyRequirements,
                color: AppColors.requirements,
              ),
            // Safety Meeting Points, unlike the library above, is
            // field-level content a Site Manager prepares for their own
            // Foremen — reachable by the same canManageOrgContent
            // boundary as Projects, not the admin-only library gate.
            if (canManageOrgContent)
              const NavSectionEntry(
                icon: Icons.list_alt_outlined,
                selectedIcon: Icons.list_alt,
                label: 'Safety Meeting Points',
                route: AppRoutes.manageSafetyMeetingPoints,
                color: AppColors.meetings,
              ),
          ],
        ),
    ];
  }
}

/// Branding shown above the navigation items: the app wordmark plus the
/// one company every user works under.
///
/// PHASE 1 (single-company model): "JV ALMA CIS" is shown as static
/// identity text, not a selectable/switchable control — there was
/// previously an [OrganizationSwitcher] here for the (now-removed)
/// multi-organization case; that concept no longer applies.
///
/// Below the wordmark it names the signed-in user and their role — the same
/// role badge the dashboard banner shows — so it is always clear whose
/// view of the app this is.
class _SidebarHeader extends StatelessWidget {
  const _SidebarHeader({this.userName, this.role});

  final String? userName;
  final AppRole? role;

  @override
  Widget build(BuildContext context) {
    // The app bar carries no title of its own — this header is the app's
    // only wordmark: "JVA Safety" in bold white on the brand gradient,
    // with the one company every user works under beneath it, and the
    // navigation sections directly below.
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
      decoration: BoxDecoration(
        gradient: AppColors.brandGradient,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.secondary,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.health_and_safety,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'JVA Safety',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'JV ALMA CIS',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.white.withValues(alpha: 0.85),
                  ),
                ),
                if (userName?.trim().isNotEmpty ?? false) ...[
                  const SizedBox(height: 10),
                  Text(
                    userName!.trim(),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                if (role != null) ...[
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: DashboardHeader.roleColor(role!),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      role!.label,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: AppColors.onColor(
                          DashboardHeader.roleColor(role!),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Lets the user pick System/Light/Dark for this app specifically — see
/// [ThemeController]'s doc comment for why an in-app override exists
/// alongside following the OS setting. A checkmark on the entry matching
/// [ThemeController.mode] shows the current choice; the icon itself reflects
/// which theme is ACTUALLY being rendered right now (relevant when the
/// choice is System, where the rendered theme depends on the OS/browser
/// signal, not a fixed icon).
class _ThemeModeAction extends StatelessWidget {
  const _ThemeModeAction();

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ThemeController>();
    final isDarkNow = Theme.of(context).brightness == Brightness.dark;
    return PopupMenuButton<ThemeMode>(
      tooltip: 'Appearance',
      icon: Icon(
        isDarkNow ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
      ),
      onSelected: controller.setMode,
      itemBuilder: (context) => [
        for (final mode in ThemeMode.values)
          CheckedPopupMenuItem(
            value: mode,
            checked: controller.mode == mode,
            child: Text(switch (mode) {
              ThemeMode.system => 'System',
              ThemeMode.light => 'Light',
              ThemeMode.dark => 'Dark',
            }),
          ),
      ],
    );
  }
}

/// The notification bell action shown in the app bar: an icon button that
/// navigates to [AppRoutes.notifications], with a small unread-count badge
/// when the signed-in user has unread notifications.
///
/// Streams [NotificationRepository.watchForRecipient] directly rather than
/// [NotificationRepository.watchUnreadForRecipient] so the same stream can
/// answer both "how many" (for the badge) and, later if needed, richer
/// previews — the unread-only query exists for [NotificationsScreen]-style
/// consumers that only ever need the count, not this one.
class _NotificationBellAction extends StatefulWidget {
  const _NotificationBellAction({
    required this.organizationId,
    required this.uid,
  });

  final String organizationId;
  final String uid;

  @override
  State<_NotificationBellAction> createState() =>
      _NotificationBellActionState();
}

class _NotificationBellActionState extends State<_NotificationBellAction> {
  NotificationRepository? _repository;

  NotificationRepository _repositoryFor(String organizationId) {
    final existing = _repository;
    if (existing != null && existing.organizationId == organizationId) {
      return existing;
    }
    final created = NotificationRepository(
      firestoreService: FirestoreService(),
      organizationId: organizationId,
    );
    _repository = created;
    return created;
  }

  @override
  Widget build(BuildContext context) {
    return LiveStreamBuilder<List<AppNotification>>(
      streamKey: (widget.organizationId, widget.uid),
      stream: () => _repositoryFor(
        widget.organizationId,
      ).watchUnreadForRecipient(widget.uid),
      builder: (context, snapshot) {
        final unreadCount = snapshot.data?.length ?? 0;

        return Stack(
          clipBehavior: Clip.none,
          children: [
            IconButton(
              tooltip: 'Notifications',
              icon: const Icon(Icons.notifications_outlined),
              onPressed: () => context.go(AppRoutes.notifications),
            ),
            if (unreadCount > 0)
              Positioned(
                right: 6,
                top: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.error,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  constraints: const BoxConstraints(
                    minWidth: 16,
                    minHeight: 16,
                  ),
                  child: Text(
                    unreadCount > 9 ? '9+' : '$unreadCount',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 10),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
