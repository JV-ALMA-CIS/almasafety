import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/analytics/data/analytics_repository.dart';
import 'package:jva_safety/features/analytics/presentation/analytics_screen.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/membership.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/organizations/data/organization_repository.dart';
import 'package:jva_safety/features/organizations/data/project_repository.dart';
import 'package:jva_safety/features/organizations/data/site_repository.dart';

class _FakeSession extends SessionController {
  _FakeSession({required AppRole? role, String? organizationId})
    : _profile = UserProfile(
        uid: 'uid-1',
        name: 'Test User',
        email: 'user@example.com',
        accountStatus: AccountStatus.active,
        // platformRole is admin-only now; every other role lives on the
        // active Membership instead.
        platformRole: role == AppRole.admin ? role : null,
      ),
      _membership =
          role == null || role == AppRole.admin || organizationId == null
          ? null
          : Membership(
              organizationId: organizationId,
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
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<void> seedOrg(String id) async {
    await firestore.doc('organizations/$id').set({
      'name': 'Org $id',
      'code': 'CODE-$id',
      'status': 'active',
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  Widget wrap({required AppRole? role, String? organizationId}) {
    // Built even when `organizationId` starts null (an Admin with no
    // membership): OrganizationScopeSelector now auto-selects a sole
    // seeded organization rather than leaving the picker showing forever,
    // so the screen may resolve an organization id itself once the fake
    // Firestore stream settles — these repositories must be fake-backed
    // for that case too, not only when the caller already knows the id.
    const fallbackOrganizationId = 'alpha';
    final resolvedOrganizationId = organizationId ?? fallbackOrganizationId;
    return ChangeNotifierProvider<SessionController>(
      create: (_) => _FakeSession(role: role, organizationId: organizationId),
      child: MaterialApp(
        home: Scaffold(
          body: AnalyticsScreen(
            repository: AnalyticsRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: resolvedOrganizationId,
            ),
            projectRepository: ProjectRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: resolvedOrganizationId,
            ),
            siteRepository: SiteRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: resolvedOrganizationId,
            ),
            organizationRepository: OrganizationRepository(
              firestoreService: FirestoreService(firestore: firestore),
            ),
          ),
        ),
      ),
    );
  }

  group('AnalyticsScreen (Admin)', () {
    testWidgets('an Admin with one organization is taken straight to the '
        'dashboard — nothing to pick', (tester) async {
      await seedOrg('alpha');

      await tester.pumpWidget(wrap(role: AppRole.admin, organizationId: null));
      await tester.pumpAndSettle();

      expect(
        find.text('Analytics is available to Admins and Site Managers.'),
        findsNothing,
      );
      // The sole organization is auto-selected — see
      // OrganizationScopeSelector's own doc comment — so the picker never
      // appears and the Admin lands directly on the dashboard.
      expect(find.text('Organization'), findsNothing);
      expect(find.text('Analytics'), findsOneWidget);
      expect(find.text('Refresh'), findsOneWidget);
    });

    testWidgets('shows an organization picker instead of being blocked', (
      tester,
    ) async {
      await seedOrg('alpha');
      await seedOrg('beta');

      await tester.pumpWidget(wrap(role: AppRole.admin, organizationId: null));
      await tester.pumpAndSettle();

      expect(
        find.text('Analytics is available to Admins and Site Managers.'),
        findsNothing,
      );
      expect(find.text('Organization'), findsOneWidget);
    });

    testWidgets('a reviewer with an organization sees the dashboard '
        'controls directly', (tester) async {
      await seedOrg('alpha');

      await tester.pumpWidget(
        wrap(role: AppRole.siteManager, organizationId: 'alpha'),
      );
      await tester.pumpAndSettle();

      expect(find.text('Analytics'), findsOneWidget);
      expect(find.text('Refresh'), findsOneWidget);
    });

    testWidgets('a foreman with an organization also sees the dashboard '
        '(reviewer authority includes Foreman)', (tester) async {
      await seedOrg('alpha');

      await tester.pumpWidget(
        wrap(role: AppRole.foreman, organizationId: 'alpha'),
      );
      await tester.pumpAndSettle();

      expect(find.text('Analytics'), findsOneWidget);
      expect(find.text('Refresh'), findsOneWidget);
    });
  });

  group('AnalyticsScreen (non-reviewer)', () {
    testWidgets('a worker is refused regardless of organization', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(role: AppRole.worker, organizationId: 'alpha'),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Analytics is available to Admins and Site Managers.'),
        findsOneWidget,
      );
    });
  });
}
