import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/membership.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/routing/app_routes.dart';
import 'package:jva_safety/routing/app_shell.dart';

/// A session controller reporting a fixed profile/membership, mirroring the
/// fake used in organizations_screen_test.dart/administration_screen_test.dart.
class _FakeSession extends SessionController {
  _FakeSession({
    required AppRole? role,
    bool transientSiteManagerMarker = false,
  }) : _profile = UserProfile(
         uid: 'uid-1',
         name: 'Test User',
         email: 'test@example.com',
         accountStatus: AccountStatus.active,
         platformRole: role == AppRole.admin
             ? role
             : (transientSiteManagerMarker ? AppRole.siteManager : null),
       ),
       _membership = role == null || role == AppRole.admin
           ? null
           : Membership(
               organizationId: 'org-a',
               role: role,
               status: MembershipStatus.active,
             );

  final UserProfile _profile;
  final Membership? _membership;

  @override
  UserProfile? get profile => _profile;

  // Deliberately empty even when a membership exists: AppShell's header
  // mounts a real, uninjectable OrganizationSwitcher whenever `memberships`
  // is non-empty (it resolves organization names via a real
  // OrganizationRepository talking to live Firebase), and its app-bar
  // action mounts a real _NotificationBellAction whenever
  // activeOrganizationId is non-null — this test file has no way to fake
  // either and does not need to: its only concern is nav-SECTION
  // visibility, which is driven by activeMembership alone (overridden
  // directly below, independent of `memberships`/`activeOrganizationId`).
  @override
  List<Membership> get memberships => const [];

  @override
  String? get activeOrganizationId => null;

  @override
  Membership? get activeMembership => _membership;
}

void main() {
  Widget wrap({
    required AppRole? role,
    bool transientSiteManagerMarker = false,
    Size viewport = const Size(1600, 900),
  }) {
    final router = GoRouter(
      initialLocation: AppRoutes.dashboard,
      routes: [
        ShellRoute(
          builder: (context, state, child) => AppShell(child: child),
          routes: [
            GoRoute(
              path: AppRoutes.dashboard,
              builder: (context, state) =>
                  const Scaffold(body: Text('Dashboard body')),
            ),
            GoRoute(
              path: AppRoutes.projects,
              builder: (context, state) =>
                  const Scaffold(body: Text('Projects body')),
            ),
            GoRoute(
              path: AppRoutes.hazards,
              builder: (context, state) =>
                  const Scaffold(body: Text('Hazards body')),
            ),
            GoRoute(
              path: AppRoutes.administration,
              builder: (context, state) =>
                  const Scaffold(body: Text('Administration body')),
            ),
          ],
        ),
      ],
    );

    return ChangeNotifierProvider<SessionController>(
      create: (_) => _FakeSession(
        role: role,
        transientSiteManagerMarker: transientSiteManagerMarker,
      ),
      child: MaterialApp.router(routerConfig: router),
    );
  }

  /// Opens the drawer on a narrow (mobile/tablet) viewport, where navigation
  /// lives behind the hamburger icon rather than a persistent rail.
  Future<void> openDrawer(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
  }

  group('AppShell navigation — role visibility', () {
    testWidgets('an Admin sees every section', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrap(role: AppRole.admin));
      await tester.pumpAndSettle();
      await openDrawer(tester);

      expect(find.text('Dashboard'), findsOneWidget);
      expect(find.text('OPERATIONS'), findsOneWidget);
      expect(find.text('Projects'), findsOneWidget);
      expect(find.text('SAFETY'), findsOneWidget);
      expect(find.text('Hazards'), findsOneWidget);
      expect(find.text('Corrective Actions'), findsOneWidget);
      expect(find.text('Safety Alerts'), findsOneWidget);
      expect(find.text('MEETINGS & LEARNING'), findsOneWidget);
      expect(find.text('Daily Safety Meetings'), findsOneWidget);
      expect(find.text('Safety Learning'), findsOneWidget);
      expect(find.text('Safety Videos'), findsOneWidget);
      expect(find.text('INSIGHTS'), findsOneWidget);
      expect(find.text('Analytics'), findsOneWidget);

      // The drawer's ListView can be taller than the viewport with every
      // section visible for an Admin — ListView only builds items near the
      // visible range, so scroll all the way to the last entry first; every
      // entry above it is then within the built (if not strictly visible)
      // range and findable.
      await tester.dragUntilVisible(
        find.text('Safety Meeting Points'),
        find.byType(ListView),
        const Offset(0, -300),
      );
      expect(find.text('Reports'), findsOneWidget);
      expect(find.text('ADMINISTRATION'), findsOneWidget);
      expect(find.text('Administration'), findsWidgets);
      expect(find.text('Pending Approvals'), findsOneWidget);
      // Admin-only company-wide libraries.
      expect(find.text('Safety Learning Library'), findsOneWidget);
      expect(find.text('Safety Meeting Points'), findsOneWidget);
    });

    testWidgets(
      'a Site Manager sees Operations, Safety, Meetings & Learning, '
      'Insights and Administration, but not the Admin-only libraries',
      (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(wrap(role: AppRole.siteManager));
        await tester.pumpAndSettle();
        await openDrawer(tester);

        expect(find.text('OPERATIONS'), findsOneWidget);
        expect(find.text('Projects'), findsOneWidget);
        expect(find.text('INSIGHTS'), findsOneWidget);

        await tester.dragUntilVisible(
          find.text('ADMINISTRATION'),
          find.byType(ListView),
          const Offset(0, -300),
        );
        expect(find.text('ADMINISTRATION'), findsOneWidget);
        expect(find.text('Safety Learning Library'), findsNothing);
        expect(find.text('Safety Meeting Points'), findsNothing);
      },
    );

    testWidgets(
      'a brand-new Site Manager with no membership yet still sees '
      'Operations/Projects and Administration — the one path to their '
      'first membership',
      (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          wrap(role: null, transientSiteManagerMarker: true),
        );
        await tester.pumpAndSettle();
        await openDrawer(tester);

        expect(find.text('OPERATIONS'), findsOneWidget);

        await tester.dragUntilVisible(
          find.text('ADMINISTRATION'),
          find.byType(ListView),
          const Offset(0, -300),
        );
        expect(find.text('ADMINISTRATION'), findsOneWidget);
      },
    );

    testWidgets(
      'a Foreman sees Safety, Meetings & Learning, and Administration '
      '(they may approve Worker accounts), but not Operations or '
      'Insights (no organization-wide management/analytics standing)',
      (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(wrap(role: AppRole.foreman));
        await tester.pumpAndSettle();
        await openDrawer(tester);

        expect(find.text('SAFETY'), findsOneWidget);
        expect(find.text('MEETINGS & LEARNING'), findsOneWidget);
        expect(find.text('ADMINISTRATION'), findsOneWidget);
        expect(find.text('OPERATIONS'), findsNothing);
        expect(find.text('INSIGHTS'), findsNothing);
      },
    );

    testWidgets(
      'a Worker sees only Dashboard, Safety and Meetings & Learning — '
      'no Operations, Insights or Administration',
      (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(wrap(role: AppRole.worker));
        await tester.pumpAndSettle();
        await openDrawer(tester);

        expect(find.text('Dashboard'), findsOneWidget);
        expect(find.text('SAFETY'), findsOneWidget);
        expect(find.text('MEETINGS & LEARNING'), findsOneWidget);
        expect(find.text('OPERATIONS'), findsNothing);
        expect(find.text('INSIGHTS'), findsNothing);
        expect(find.text('ADMINISTRATION'), findsNothing);
      },
    );
  });

  group('AppShell navigation — selection and routing', () {
    testWidgets('tapping a nav entry navigates and closes the drawer', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrap(role: AppRole.admin));
      await tester.pumpAndSettle();
      await openDrawer(tester);

      await tester.tap(find.text('Hazards'));
      await tester.pumpAndSettle();

      expect(find.text('Hazards body'), findsOneWidget);
      // The drawer closed itself after selection.
      expect(find.text('SAFETY'), findsNothing);
    });

    testWidgets('desktop viewport shows a persistent rail, no drawer icon', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrap(role: AppRole.admin));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.menu), findsNothing);
      // Navigation is already visible without opening anything.
      expect(find.text('Dashboard'), findsOneWidget);
      expect(find.text('SAFETY'), findsOneWidget);

      await tester.tap(find.text('Projects'));
      await tester.pumpAndSettle();

      expect(find.text('Projects body'), findsOneWidget);
    });
  });

  group('AppShell header', () {
    testWidgets('shows the JVA Safety wordmark', (tester) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrap(role: AppRole.admin));
      await tester.pumpAndSettle();

      expect(find.text('JVA Safety'), findsWidgets);
    });
  });
}
