import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/authentication/presentation/administration_screen.dart';
import 'package:jva_safety/routing/app_routes.dart';

/// A session controller reporting a fixed profile, so the screen's own
/// capability check can be exercised without Firebase. Mirrors the fake used
/// in pending_approvals_screen_test.dart.
class _FakeSession extends SessionController {
  _FakeSession({required AppRole? role})
    : _profile = UserProfile(
        uid: 'uid-1',
        name: 'Test User',
        email: 'test@example.com',
        accountStatus: AccountStatus.active,
        organizationId: role == AppRole.admin
            ? null
            : 'jv-alma-cis',
        platformRole: role,
      );

  final UserProfile _profile;

  @override
  UserProfile? get profile => _profile;
}

void main() {
  Widget wrap({required AppRole? role}) {
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
        GoRoute(
          path: AppRoutes.manageOrganizations,
          builder: (context, state) =>
              const Scaffold(body: Text('Organizations Screen')),
        ),
      ],
    );

    return ChangeNotifierProvider<SessionController>(
      create: (_) => _FakeSession(role: role),
      child: MaterialApp.router(routerConfig: router),
    );
  }

  group('AdministrationScreen (Admin)', () {
    testWidgets('renders all four entry points', (tester) async {
      await tester.pumpWidget(wrap(role: AppRole.admin));
      await tester.pumpAndSettle();

      expect(find.text('Administration'), findsOneWidget);
      expect(find.text('Pending Approvals'), findsOneWidget);
      expect(find.text('Active Users'), findsOneWidget);
      expect(find.text('Suspended / Rejected Users'), findsOneWidget);
      expect(find.text('Organizations'), findsOneWidget);
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

    testWidgets('links through to the organizations screen', (tester) async {
      await tester.pumpWidget(wrap(role: AppRole.admin));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Organizations'));
      await tester.pumpAndSettle();

      expect(find.text('Organizations Screen'), findsOneWidget);
    });
  });

  group('AdministrationScreen (Site Manager)', () {
    testWidgets('renders all four entry points, scoped to their own org', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(role: AppRole.siteManager));
      await tester.pumpAndSettle();

      expect(find.text('Administration'), findsOneWidget);
      expect(find.text('Pending Approvals'), findsOneWidget);
      expect(find.text('Active Users'), findsOneWidget);
      expect(find.text('Suspended / Rejected Users'), findsOneWidget);
      expect(find.text('Organizations'), findsOneWidget);
    });

    testWidgets('links through to the organizations screen', (tester) async {
      await tester.pumpWidget(wrap(role: AppRole.siteManager));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Organizations'));
      await tester.pumpAndSettle();

      expect(find.text('Organizations Screen'), findsOneWidget);
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
