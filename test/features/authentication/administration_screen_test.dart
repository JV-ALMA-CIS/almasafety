import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/membership.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/authentication/presentation/administration_screen.dart';
import 'package:jva_safety/routing/app_routes.dart';

/// A session controller reporting a fixed profile/membership, so the
/// screen's own capability check can be exercised without Firebase. Mirrors
/// the fake used in pending_approvals_screen_test.dart.
class _FakeSession extends SessionController {
  _FakeSession({
    required AppRole? role,
    bool transientSiteManagerMarker = false,
  }) : _profile = UserProfile(
         uid: 'uid-1',
         name: 'Test User',
         email: 'test@example.com',
         accountStatus: AccountStatus.active,
         // platformRole is admin-only now; every other role lives on the
         // active Membership instead — except a Site Manager just approved
         // with no organization yet, who has no membership at all and is
         // signalled by this transient marker (account_approval.ts's
         // approveAccount).
         platformRole: role == AppRole.admin
             ? role
             : (transientSiteManagerMarker ? AppRole.siteManager : null),
       ),
       _membership = role == null || role == AppRole.admin
           ? null
           : Membership(
               organizationId: 'jv-alma-cis',
               role: role,
               status: MembershipStatus.active,
             );

  final UserProfile _profile;
  final Membership? _membership;

  @override
  UserProfile? get profile => _profile;

  @override
  String? get activeOrganizationId => _membership?.organizationId;

  @override
  Membership? get activeMembership => _membership;
}

void main() {
  Widget wrap({
    required AppRole? role,
    bool transientSiteManagerMarker = false,
  }) {
    final router = GoRouter(
      initialLocation: AppRoutes.administration,
      routes: [
        GoRoute(
          path: AppRoutes.administration,
          builder: (context, state) => const AdministrationScreen(),
        ),
        GoRoute(
          path: AppRoutes.pendingApprovals,
          builder: (context, state) =>
              const Scaffold(body: Text('Pending Approvals Screen')),
        ),
        GoRoute(
          path: AppRoutes.activeUsers,
          builder: (context, state) =>
              const Scaffold(body: Text('Active Users Screen')),
        ),
        GoRoute(
          path: AppRoutes.suspendedUsers,
          builder: (context, state) =>
              const Scaffold(body: Text('Suspended Users Screen')),
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

  group('AdministrationScreen (Admin)', () {
    testWidgets('renders three entry points — PHASE 1 removed the fourth, '
        'Organizations, under the single-company model', (tester) async {
      await tester.pumpWidget(wrap(role: AppRole.admin));
      await tester.pumpAndSettle();

      expect(find.text('Administration'), findsOneWidget);
      expect(find.text('Pending Approvals'), findsOneWidget);
      expect(find.text('Active Users'), findsOneWidget);
      expect(find.text('Suspended / Rejected Users'), findsOneWidget);
      expect(find.text('Organizations'), findsNothing);
    });

    testWidgets('links through to the approvals inbox', (tester) async {
      await tester.pumpWidget(wrap(role: AppRole.admin));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Pending Approvals'));
      await tester.pumpAndSettle();

      expect(find.text('Pending Approvals Screen'), findsOneWidget);
    });

    testWidgets('links through to the active users list', (tester) async {
      await tester.pumpWidget(wrap(role: AppRole.admin));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Active Users'));
      await tester.pumpAndSettle();

      expect(find.text('Active Users Screen'), findsOneWidget);
    });

    testWidgets('links through to the suspended/rejected users list', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(role: AppRole.admin));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Suspended / Rejected Users'));
      await tester.pumpAndSettle();

      expect(find.text('Suspended Users Screen'), findsOneWidget);
    });
  });

  group('AdministrationScreen (Site Manager)', () {
    testWidgets('renders the same three entry points, JV ALMA CIS-wide', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(role: AppRole.siteManager));
      await tester.pumpAndSettle();

      expect(find.text('Administration'), findsOneWidget);
      expect(find.text('Pending Approvals'), findsOneWidget);
      expect(find.text('Active Users'), findsOneWidget);
      expect(find.text('Suspended / Rejected Users'), findsOneWidget);
      expect(find.text('Organizations'), findsNothing);
    });
  });

  group('AdministrationScreen (brand-new Site Manager, no membership yet)', () {
    testWidgets('can still reach Administration — the first-time company setup '
        'prompt lives on the Operations/Projects landing page instead '
        '(ProjectsRouterScreen), not here', (tester) async {
      await tester.pumpWidget(
        wrap(role: null, transientSiteManagerMarker: true),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('You do not have permission to view administration.'),
        findsNothing,
      );
      expect(find.text('Pending Approvals'), findsOneWidget);
    });
  });

  group('AdministrationScreen (non-platform-administrator)', () {
    testWidgets('a user with no role sees no administration content', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(role: null));
      await tester.pumpAndSettle();

      expect(
        find.text('You do not have permission to view administration.'),
        findsOneWidget,
      );
    });
  });
}
