import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../core/services/firestore_service.dart';
import '../core/services/session_controller.dart';
import '../core/widgets/responsive_scaffold.dart';
import '../features/authentication/domain/app_role.dart';
import '../features/notifications/data/notification_repository.dart';
import '../features/notifications/domain/app_notification.dart';
import 'app_routes.dart';

/// Primary navigation destinations shown in the app shell.
///
/// This is a starter set for the foundation; per-role navigation (e.g. a
/// simplified worker shell) will be introduced when role-specific
/// presentation is built out.
const _shellDestinations = [
  NavDestinationItem(
    icon: Icons.dashboard_outlined,
    selectedIcon: Icons.dashboard,
    label: 'Dashboard',
  ),
  NavDestinationItem(
    icon: Icons.groups_outlined,
    selectedIcon: Icons.groups,
    label: 'Workers',
  ),
  NavDestinationItem(
    icon: Icons.warning_amber_outlined,
    selectedIcon: Icons.warning_amber,
    label: 'Hazards',
  ),
  NavDestinationItem(
    icon: Icons.fact_check_outlined,
    selectedIcon: Icons.fact_check,
    label: 'Meetings',
  ),
  NavDestinationItem(
    icon: Icons.bar_chart_outlined,
    selectedIcon: Icons.bar_chart,
    label: 'Analytics',
  ),
];

const _shellRoutes = [
  AppRoutes.dashboard,
  AppRoutes.workers,
  AppRoutes.hazards,
  AppRoutes.dailySafetyMeetings,
  AppRoutes.analytics,
];

/// Wraps the currently routed screen with the responsive navigation shell.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).uri.toString();
    final selectedIndex = _shellRoutes.indexOf(location).clamp(0, _shellRoutes.length - 1);

    // Corrective Actions, Safety Alerts, Reports, the approvals inbox and
    // the administration dashboard are all role-gated capabilities, not
    // primary destinations, so they are app-bar actions rather than nav
    // items: adding a conditional entry to _shellDestinations would make the
    // nav index depend on the user, and the index arithmetic above assumes a
    // fixed list. Hiding them is UX only — the router redirects unauthorized
    // users away, and the callables/rules behind each screen check the same
    // role server-side.
    final sessionController = context.watch<SessionController>();
    final profile = sessionController.profile;
    final isPlatformAdministrator = profile?.isPlatformAdministrator ?? false;
    // A non-Admin's review/org-management authority now lives on their
    // active Membership's role, not on the profile's (now admin-only)
    // platformRole — except for the one transient case of a Site Manager
    // just approved with no organization yet, who has no membership at all
    // and is signalled instead by profile.platformRole == siteManager (see
    // account_approval.ts's approveAccount). Both must be checked or that
    // Site Manager can never reach the one screen (Organizations) that would
    // give them their first membership.
    final canReviewPendingAccounts = isPlatformAdministrator ||
        (sessionController.activeMembership?.role.canReviewPendingAccounts ??
            false);
    final canManageOrgContent = isPlatformAdministrator ||
        (sessionController.activeMembership?.role.canManageOrgContent ??
            false) ||
        profile?.platformRole == AppRole.siteManager;

    return ResponsiveScaffold(
      title: 'JVA Safety',
      destinations: _shellDestinations,
      selectedIndex: selectedIndex < 0 ? 0 : selectedIndex,
      onDestinationSelected: (index) => context.go(_shellRoutes[index]),
      actions: [
        if (sessionController.activeOrganizationId != null &&
            profile?.uid != null)
          _NotificationBellAction(
            organizationId: sessionController.activeOrganizationId!,
            uid: profile!.uid,
          ),
        if (canReviewPendingAccounts) ...[
          IconButton(
            tooltip: 'Corrective Actions',
            icon: const Icon(Icons.build_outlined),
            onPressed: () => context.go(AppRoutes.correctiveActions),
          ),
          IconButton(
            tooltip: 'Safety Alerts',
            icon: const Icon(Icons.warning_amber_outlined),
            onPressed: () => context.go(AppRoutes.safetyAlerts),
          ),
          IconButton(
            tooltip: 'Reports',
            icon: const Icon(Icons.summarize_outlined),
            onPressed: () => context.go(AppRoutes.reports),
          ),
        ],
        if (canManageOrgContent)
          IconButton(
            tooltip: 'Administration',
            icon: const Icon(Icons.admin_panel_settings_outlined),
            onPressed: () => context.go(AppRoutes.administration),
          ),
        if (canReviewPendingAccounts)
          IconButton(
            tooltip: 'Pending Approvals',
            icon: const Icon(Icons.how_to_reg_outlined),
            onPressed: () => context.go(AppRoutes.pendingApprovals),
          ),
      ],
      body: child,
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
  const _NotificationBellAction({required this.organizationId, required this.uid});

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
