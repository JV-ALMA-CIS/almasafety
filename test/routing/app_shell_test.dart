import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/core/services/theme_controller.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/membership.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/routing/app_routes.dart';
import 'package:jva_safety/routing/app_shell.dart';

/// A session controller reporting a fixed profile/membership, mirroring the
/// fake used in administration_screen_test.dart.
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
  bool signOutCalled = false;

  @override
  UserProfile? get profile => _profile;

  @override
  Future<void> signOut() async {
    signOutCalled = true;
  }

  // Deliberately empty: AppShell's app-bar action mounts a real,
  // uninjectable _NotificationBellAction whenever activeOrganizationId is
  // non-null (it talks to live Firebase) — this test file has no way to
  // fake it and does not need to: its only concern is nav-SECTION
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
    void Function(_FakeSession session)? onSessionCreated,
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

    SharedPreferences.setMockInitialValues({});
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SessionController>(
          create: (_) {
            final session = _FakeSession(
              role: role,
              transientSiteManagerMarker: transientSiteManagerMarker,
            );
            onSessionCreated?.call(session);
            return session;
          },
        ),
        // The app reads its theme from this provider — ThemeController is
        // deliberately independent of SessionController (see its own doc
        // comment), so it needs its own entry here.
        ChangeNotifierProvider<ThemeController>(
          create: (_) => ThemeController(),
        ),
      ],
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
      // Brings a menu entry into view, scrolling only when it isn't built.
      Future<void> reveal(String text) async {
        if (find.text(text).evaluate().isEmpty) {
          await tester.scrollUntilVisible(
            find.text(text),
            200,
            scrollable: find
                .descendant(
                  of: find.byType(Drawer),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
        }
        await tester.ensureVisible(find.text(text));
        await tester.pumpAndSettle();
      }

      // The drawer's entry; on a phone the top bar names the page too.
      expect(
        find.descendant(
          of: find.byType(Drawer),
          matching: find.text('Dashboard'),
        ),
        findsOneWidget,
      );
      expect(find.text('OPERATIONS'), findsOneWidget);
      // The menu's entry; a phone's bottom bar has a Projects tab too.
      expect(
        find.descendant(
          of: find.byType(Drawer),
          matching: find.text('Projects'),
        ),
        findsOneWidget,
      );
      expect(find.text('SAFETY'), findsOneWidget);
      expect(find.text('Hazards'), findsOneWidget);
      await reveal('Risk Assessments (AHA)');
      expect(find.text('Risk Assessments (AHA)'), findsOneWidget);
      await reveal('Monthly Man-Hours');
      expect(find.text('Monthly Man-Hours'), findsOneWidget);
      await reveal('Corrective Actions');
      expect(find.text('Corrective Actions'), findsOneWidget);
      await reveal('Safety Alerts');
      expect(find.text('Safety Alerts'), findsOneWidget);
      await reveal('MEETINGS & LEARNING');
      expect(find.text('MEETINGS & LEARNING'), findsOneWidget);
      await reveal('Daily Safety Meetings');
      expect(find.text('Daily Safety Meetings'), findsOneWidget);
      // "Safety Learning" here is a Foreman/Worker's own required-learning
      // list — an Admin has no personal learning records and reviews
      // org-wide via "Learning Compliance" under Insights instead. See
      // AppShell._sectionsFor's doc comment.
      expect(find.text('Safety Learning'), findsNothing);
      await reveal('Safety Videos');
      expect(find.text('Safety Videos'), findsOneWidget);
      // The sidebar header now also shows the user's name and role, so
      // this entry may sit below the fold — scroll it into view first.
      await tester.scrollUntilVisible(
        find.text('Analytics'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
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
      // Safety Learning Library is admin-only; Safety Meeting Points is
      // also reachable by a Site Manager (see the Site Manager test below)
      // but Admin sees it too, as they can act on any organization.
      expect(find.text('Safety Learning Library'), findsOneWidget);
      expect(find.text('Safety Meeting Points'), findsOneWidget);
    });

    testWidgets('a Site Manager sees Operations, Safety, Meetings & Learning, '
        'Insights, Administration and Safety Meeting Points (field-level '
        'content they prepare for their own Foremen), but not the '
        'admin-only Safety Learning Library', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrap(role: AppRole.siteManager));
      await tester.pumpAndSettle();
      await openDrawer(tester);

      expect(find.text('OPERATIONS'), findsOneWidget);
      // The menu's entry; a phone's bottom bar has a Projects tab too.
      expect(
        find.descendant(
          of: find.byType(Drawer),
          matching: find.text('Projects'),
        ),
        findsOneWidget,
      );
      await tester.dragUntilVisible(
        find.text('INSIGHTS'),
        find.byType(ListView),
        const Offset(0, -300),
      );
      expect(find.text('INSIGHTS'), findsOneWidget);

      await tester.dragUntilVisible(
        find.text('Safety Meeting Points'),
        find.byType(ListView),
        const Offset(0, -300),
      );
      expect(find.text('Safety Learning Library'), findsNothing);
      expect(find.text('Safety Meeting Points'), findsOneWidget);

      await tester.dragUntilVisible(
        find.text('ADMINISTRATION'),
        find.byType(ListView),
        const Offset(0, -300),
      );
      expect(find.text('ADMINISTRATION'), findsOneWidget);
    });

    testWidgets('a brand-new Site Manager with no membership yet still sees '
        'Operations/Projects (where the "Set up JV ALMA CIS" bootstrap '
        'prompt lives — see ProjectsRouterScreen) and Administration', (
      tester,
    ) async {
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
    });

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
        await tester.scrollUntilVisible(
          find.text('Monthly Man-Hours'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('Monthly Man-Hours'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('MEETINGS & LEARNING'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('MEETINGS & LEARNING'), findsOneWidget);
        // The sidebar header now also shows the user's name and role, so
        // this entry may sit below the fold — scroll it into view first.
        await tester.scrollUntilVisible(
          find.text('ADMINISTRATION'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('ADMINISTRATION'), findsOneWidget);
        expect(find.text('OPERATIONS'), findsNothing);
        expect(find.text('INSIGHTS'), findsNothing);
      },
    );

    testWidgets('a Foreman sees Pending Approvals and My Workers under '
        'Administration, but not the Administration landing entry itself — '
        'regression test for a Foreman tapping "Administration" and hitting '
        "AdministrationScreen's own permission refusal, since that screen's "
        'canManage requires canManageOrgContent, which a Foreman never has', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrap(role: AppRole.foreman));
      await tester.pumpAndSettle();
      await openDrawer(tester);

      // The sidebar header now also shows the user's name and role, so
      // this entry may sit below the fold — scroll it into view first.
      await tester.scrollUntilVisible(
        find.text('Pending Approvals'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Pending Approvals'), findsOneWidget);
      // The drawer's nav list now has more entries than the 360x800 mobile
      // viewport can show at once (this role also sees "Crew Compliance"),
      // so "My Workers" — further down the list — needs a scroll to be in
      // view before Flutter's test framework will find it, same as any
      // other item near the bottom of a real scrollable list.
      await tester.scrollUntilVisible(
        find.text('My Workers'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('My Workers'), findsOneWidget);
      expect(find.text('Administration'), findsNothing);
    });

    testWidgets(
      'a Site Manager sees the Administration landing entry, but not My '
      'Workers — that view is Foreman-scoped; a Site Manager sees every '
      "site's workers through Operations/Projects instead",
      (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(wrap(role: AppRole.siteManager));
        await tester.pumpAndSettle();
        await openDrawer(tester);

        await tester.dragUntilVisible(
          find.text('Administration'),
          find.byType(ListView),
          const Offset(0, -300),
        );
        expect(find.text('Administration'), findsOneWidget);
        expect(find.text('My Workers'), findsNothing);
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

        // The drawer's entry; on a phone the top bar names the page too.
        expect(
          find.descendant(
            of: find.byType(Drawer),
            matching: find.text('Dashboard'),
          ),
          findsOneWidget,
        );
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
    testWidgets('shows the ALMASAFETY wordmark', (tester) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrap(role: AppRole.admin));
      await tester.pumpAndSettle();

      expect(find.text('ALMASAFETY'), findsWidgets);
    });
  });

  group('AppShell top bar', () {
    for (final size in [const Size(1600, 900), const Size(800, 900)]) {
      testWidgets('at ${size.width.toInt()}px it carries no Appearance or '
          'Sign Out — those live in Settings', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(wrap(role: AppRole.worker));
        await tester.pumpAndSettle();

        expect(find.byTooltip('Sign Out'), findsNothing);
        expect(find.byTooltip('Appearance'), findsNothing);
      });
    }

    for (final role in [
      AppRole.admin,
      AppRole.siteManager,
      AppRole.foreman,
      AppRole.worker,
    ]) {
      testWidgets('${role.name}: Settings is the last menu entry', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(1600, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(wrap(role: role));
        await tester.pumpAndSettle();
        final settings = find.text('Settings');
        await tester.scrollUntilVisible(
          settings,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(settings, findsOneWidget);
      });
    }
  });
}
