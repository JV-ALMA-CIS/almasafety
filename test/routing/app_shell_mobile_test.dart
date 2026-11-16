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
import 'package:jva_safety/features/organizations/domain/organization.dart';
import 'package:jva_safety/features/organizations/domain/organization_record_status.dart';
import 'package:jva_safety/features/organizations/domain/project.dart';
import 'package:jva_safety/features/organizations/domain/site.dart';
import 'package:jva_safety/routing/app_routes.dart';
import 'package:jva_safety/routing/app_shell.dart';
import 'package:jva_safety/routing/route_extra_codec.dart';

class _FakeSession extends SessionController {
  _FakeSession(AppRole role)
    : _profile = UserProfile(
        uid: 'uid-1',
        name: 'Test User',
        email: 'test@example.com',
        accountStatus: AccountStatus.active,
        platformRole: role == AppRole.admin ? role : null,
      ),
      _membership = role == AppRole.admin
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
  Future<void> signOut() async => signOutCalled = true;

  @override
  List<Membership> get memberships => const [];

  // Null keeps the live-Firebase notification bell out of the test.
  @override
  String? get activeOrganizationId => null;

  @override
  Membership? get activeMembership => _membership;
}

const _org = Organization(
  id: 'org-a',
  name: 'JV ALMA CIS',
  code: 'JVA',
  status: OrganizationRecordStatus.active,
);
const _project = Project(
  id: 'p1',
  organizationId: 'org-a',
  name: 'Rosslyn',
  code: 'ROS',
  status: OrganizationRecordStatus.active,
);
const _site = Site(
  id: 's1',
  organizationId: 'org-a',
  projectId: 'p1',
  name: 'Site A',
  code: 'SA',
  status: OrganizationRecordStatus.active,
);

/// Each test route shows its path and, when given, the site's name from
/// `extra` — so a test can see which context arrived.
Widget _page(GoRouterState state) {
  final extra = state.extra;
  final siteName =
      extra is ({Organization organization, Project project, Site site})
      ? extra.site.name
      : extra is ({Organization organization, Project project})
      ? extra.project.name
      : '-';
  return Scaffold(body: Text('${state.matchedLocation} body ($siteName)'));
}

void main() {
  late GoRouter router;

  Widget wrap({
    AppRole role = AppRole.admin,
    String initial = AppRoutes.dashboard,
    Object? extra,
  }) {
    router = GoRouter(
      initialLocation: initial,
      initialExtra: extra,
      extraCodec: RouteExtraCodec(),
      routes: [
        ShellRoute(
          builder: (context, state, child) => AppShell(child: child),
          routes: [
            for (final path in [
              AppRoutes.dashboard,
              AppRoutes.projects,
              AppRoutes.hazards,
              AppRoutes.administration,
              AppRoutes.activeUsers,
              AppRoutes.manageSites,
              AppRoutes.manageActivities,
              AppRoutes.manageSiteWorkers,
              AppRoutes.safetyVideos,
              AppRoutes.reportSafetyIssue,
              AppRoutes.safetyLearning,
              AppRoutes.dailySafetyMeetings,
              AppRoutes.analytics,
              AppRoutes.reports,
              AppRoutes.safetyLearningCompliance,
              AppRoutes.settings,
            ])
              GoRoute(path: path, builder: (context, state) => _page(state)),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    SharedPreferences.setMockInitialValues({});
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SessionController>(
          create: (_) => _FakeSession(role),
        ),
        ChangeNotifierProvider<ThemeController>(
          create: (_) => ThemeController(),
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    );
  }

  void setWidth(WidgetTester tester, double width) {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Finder barTitle(String text) =>
      find.descendant(of: find.byType(AppBar), matching: find.text(text));

  Finder tab(String label) => find.descendant(
    of: find.byType(NavigationBar),
    matching: find.text(label),
  );

  List<String> tabLabels(WidgetTester tester) => [
    for (final destination in tester.widgetList<NavigationDestination>(
      find.byType(NavigationDestination),
    ))
      destination.label,
  ];

  group('mobile top bar', () {
    testWidgets('the menu button, the page title and notifications — no '
        'Home shortcut, Appearance or Sign Out', (tester) async {
      setWidth(tester, 360);
      await tester.pumpWidget(wrap(initial: AppRoutes.safetyVideos));
      await tester.pumpAndSettle();
      expect(barTitle('Safety Videos'), findsOneWidget);
      final bar = find.byType(AppBar);
      expect(
        find.descendant(of: bar, matching: find.byIcon(Icons.menu)),
        findsOneWidget,
      );
      for (final icon in [
        Icons.home_outlined,
        Icons.more_vert,
        Icons.logout_outlined,
      ]) {
        expect(
          find.descendant(of: bar, matching: find.byIcon(icon)),
          findsNothing,
        );
      }
      expect(find.byType(BackButton), findsNothing);
    });

    testWidgets('Sites → back goes to Projects', (tester) async {
      setWidth(tester, 360);
      await tester.pumpWidget(
        wrap(
          initial: AppRoutes.manageSites,
          extra: (organization: _org, project: _project),
        ),
      );
      await tester.pumpAndSettle();
      expect(barTitle('Sites'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('/projects body (-)'), findsOneWidget);
      expect(barTitle('Projects'), findsOneWidget);
    });

    for (final (path, title) in [
      (AppRoutes.manageActivities, 'Activities'),
      (AppRoutes.manageSiteWorkers, 'Site Workers'),
    ]) {
      testWidgets('$title → back returns to that project\'s Sites, context '
          'kept', (tester) async {
        setWidth(tester, 360);
        await tester.pumpWidget(
          wrap(
            initial: path,
            extra: (organization: _org, project: _project, site: _site),
          ),
        );
        await tester.pumpAndSettle();
        expect(barTitle(title), findsOneWidget);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(
          find.text('/administration/sites body (Rosslyn)'),
          findsOneWidget,
        );
      });
    }

    testWidgets('Active Users → back to Administration', (tester) async {
      setWidth(tester, 360);
      await tester.pumpWidget(wrap(initial: AppRoutes.activeUsers));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('/administration body (-)'), findsOneWidget);
    });

    testWidgets('a long title is truncated, never overflowing', (tester) async {
      setWidth(tester, 320);
      await tester.pumpWidget(wrap(initial: AppRoutes.manageSiteWorkers));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final text = tester.widget<Text>(barTitle('Site Workers'));
      expect(text.overflow, TextOverflow.ellipsis);
      expect(text.maxLines, 1);
    });
  });

  group('mobile bottom bar', () {
    for (final (role, labels) in [
      (AppRole.admin, ['Home', 'Projects', 'Report Issue', 'Insights']),
      (AppRole.siteManager, ['Home', 'Projects', 'Report Issue', 'Insights']),
      (AppRole.foreman, ['Home', 'Meetings', 'Report Issue', 'Crew']),
      (AppRole.worker, ['Home', 'Report Issue', 'Learning', 'Meetings']),
    ]) {
      testWidgets('${role.name}: ${labels.join(', ')}', (tester) async {
        setWidth(tester, 360);
        await tester.pumpWidget(wrap(role: role));
        await tester.pumpAndSettle();
        expect(tabLabels(tester), labels);
      });
    }

    testWidgets('a tab goes to its page and is highlighted; Home returns', (
      tester,
    ) async {
      setWidth(tester, 360);
      await tester.pumpWidget(wrap(role: AppRole.worker));
      await tester.pumpAndSettle();
      await tester.tap(tab('Learning'));
      await tester.pumpAndSettle();
      expect(find.text('/safety-learning body (-)'), findsOneWidget);
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        2,
      );

      await tester.tap(tab('Home'));
      await tester.pumpAndSettle();
      expect(find.text('/dashboard body (-)'), findsOneWidget);
    });

    testWidgets('the menu at the top opens the full menu, which ends with '
        'Settings', (tester) async {
      setWidth(tester, 360);
      await tester.pumpWidget(wrap(role: AppRole.worker));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsOneWidget);
      final settings = find.descendant(
        of: find.byType(Drawer),
        matching: find.text('Settings'),
      );
      await tester.scrollUntilVisible(
        settings,
        200,
        scrollable: find
            .descendant(
              of: find.byType(Drawer),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(settings);
      await tester.pumpAndSettle();
      expect(find.text('/settings body (-)'), findsOneWidget);
      expect(find.byType(Drawer), findsNothing);
      // A page with no tab of its own highlights none.
      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.indicatorColor, Colors.transparent);
    });

    testWidgets('a Projects drill-down page keeps Projects highlighted', (
      tester,
    ) async {
      setWidth(tester, 360);
      await tester.pumpWidget(
        wrap(
          initial: AppRoutes.manageSites,
          extra: (organization: _org, project: _project),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        1,
      );
    });
  });

  group('tablet and desktop', () {
    for (final width in [600.0, 1023.0, 1024.0, 1440.0]) {
      testWidgets('at ${width.toInt()}px: no bottom bar, no bar title or back '
          'arrow, and only notifications in the top bar', (tester) async {
        setWidth(tester, width);
        await tester.pumpWidget(
          wrap(
            initial: AppRoutes.manageSites,
            extra: (organization: _org, project: _project),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(NavigationBar), findsNothing);
        expect(barTitle('Sites'), findsNothing);
        expect(find.byType(BackButton), findsNothing);
        expect(find.byTooltip('Appearance'), findsNothing);
        expect(find.byTooltip('Sign Out'), findsNothing);
      });
    }

    testWidgets('599px is still the phone layout', (tester) async {
      setWidth(tester, 599);
      await tester.pumpWidget(wrap(initial: AppRoutes.hazards));
      await tester.pumpAndSettle();
      expect(barTitle('Hazards'), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
    });
  });

  group('every width renders without overflow', () {
    for (final width in [
      320.0,
      360.0,
      412.0,
      599.0,
      600.0,
      768.0,
      1023.0,
      1024.0,
      1440.0,
    ]) {
      for (final role in [
        AppRole.admin,
        AppRole.siteManager,
        AppRole.foreman,
        AppRole.worker,
      ]) {
        testWidgets('${role.name} at ${width.toInt()}px', (tester) async {
          setWidth(tester, width);
          await tester.pumpWidget(wrap(role: role, initial: AppRoutes.hazards));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          if (width < 1024) {
            await tester.tap(find.byIcon(Icons.menu));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }
        });
      }
    }
  });

  group('titleFor / parentOf', () {
    test('every navigation route has a real title', () {
      for (final route in [
        AppRoutes.dashboard,
        AppRoutes.projects,
        AppRoutes.hazards,
        AppRoutes.incidents,
        AppRoutes.correctiveActions,
        AppRoutes.dailySafetyMeetings,
        AppRoutes.safetyLearning,
        AppRoutes.safetyVideos,
        AppRoutes.reports,
        AppRoutes.analytics,
        AppRoutes.administration,
        AppRoutes.pendingApprovals,
        AppRoutes.notifications,
        AppRoutes.manageSafetyRequirements,
      ]) {
        expect(AppShell.titleFor(route), isNot('ALMASAFETY'), reason: route);
      }
    });

    test('a drill-down page reached without its context goes back to '
        'Projects', () {
      expect(
        AppShell.parentOf(AppRoutes.manageActivities, null)?.route,
        AppRoutes.projects,
      );
      expect(AppShell.parentOf(AppRoutes.dashboard, null), isNull);
      expect(AppShell.parentOf(AppRoutes.pendingApprovals, null), isNull);
    });
  });
}
