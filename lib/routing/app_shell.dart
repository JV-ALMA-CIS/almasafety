import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../core/services/firestore_service.dart';
import '../core/services/session_controller.dart';
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
/// PHASE 1 (single-company model): the header carries only the app's own
/// "JVA Safety" branding — no organization switcher. JV ALMA CIS is the
/// one company every user works under; there is nothing to switch between,
/// so surfacing a picker (even a static "which org am I in" label) would
/// invite a question that no longer has a meaningful answer. Internally,
/// `SessionController.activeOrganizationId` still resolves to that one
/// company's Firestore id — nothing about the underlying membership model
/// changed, only what the UI shows. The app bar itself stays minimal: a
/// drawer toggle where needed, the title, and the two truly global actions
/// (Notifications, and eventually a Profile entry) — never a list of
/// feature buttons.
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
    );

    return ResponsiveScaffold(
      title: 'JVA Safety',
      header: const _SidebarHeader(),
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
            onPressed: () => Navigator.of(context).push(
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
            ),
          ],
        ),
      const NavSection(
        title: 'Safety',
        entries: [
          NavSectionEntry(
            icon: Icons.warning_amber_outlined,
            selectedIcon: Icons.warning_amber,
            label: 'Hazards',
            route: AppRoutes.hazards,
          ),
          NavSectionEntry(
            icon: Icons.build_outlined,
            selectedIcon: Icons.build,
            label: 'Corrective Actions',
            route: AppRoutes.correctiveActions,
          ),
          NavSectionEntry(
            icon: Icons.campaign_outlined,
            selectedIcon: Icons.campaign,
            label: 'Safety Alerts',
            route: AppRoutes.safetyAlerts,
          ),
        ],
      ),
      const NavSection(
        title: 'Meetings & Learning',
        entries: [
          NavSectionEntry(
            icon: Icons.fact_check_outlined,
            selectedIcon: Icons.fact_check,
            label: 'Daily Safety Meetings',
            route: AppRoutes.dailySafetyMeetings,
          ),
          NavSectionEntry(
            icon: Icons.school_outlined,
            selectedIcon: Icons.school,
            label: 'Safety Learning',
            route: AppRoutes.safetyLearning,
          ),
          NavSectionEntry(
            icon: Icons.play_circle_outline,
            selectedIcon: Icons.play_circle,
            label: 'Safety Videos',
            route: AppRoutes.safetyVideos,
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
            ),
            NavSectionEntry(
              icon: Icons.summarize_outlined,
              selectedIcon: Icons.summarize,
              label: 'Reports',
              route: AppRoutes.reports,
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
              ),
            const NavSectionEntry(
              icon: Icons.how_to_reg_outlined,
              selectedIcon: Icons.how_to_reg,
              label: 'Pending Approvals',
              route: AppRoutes.pendingApprovals,
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
class _SidebarHeader extends StatelessWidget {
  const _SidebarHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'JVA Safety',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          Text(
            'JV ALMA CIS',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
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
    return StreamBuilder<List<AppNotification>>(
      stream: _repositoryFor(
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
