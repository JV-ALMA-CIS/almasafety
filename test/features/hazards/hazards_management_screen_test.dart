import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/membership.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/corrective_actions/data/corrective_action_repository.dart';
import 'package:jva_safety/features/hazards/data/hazard_repository.dart';
import 'package:jva_safety/features/hazards/presentation/hazards_management_screen.dart';
import 'package:jva_safety/features/organizations/data/organization_repository.dart';
import 'package:jva_safety/features/organizations/data/site_repository.dart';

class _FakeSession extends SessionController {
  _FakeSession({required AppRole? role, String? organizationId})
    : _profile = UserProfile(
        uid: 'uid-1',
        name: 'Test User',
        email: 'user@example.com',
        accountStatus: AccountStatus.active,
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

  Future<void> seedHazard(
    String orgId,
    String id, {
    String category = 'electrical',
    String description = 'A hazard',
    String status = 'reported',
    String siteId = 'site-1',
    String? correctiveActionId,
    String? photoUrl,
  }) async {
    await firestore.doc('organizations/$orgId/hazards/$id').set({
      'organizationId': orgId,
      'projectId': 'project-1',
      'siteId': siteId,
      'reportedByUid': 'worker-1',
      'category': category,
      'description': description,
      'photoUrl': photoUrl,
      'status': status,
      'correctiveActionId': correctiveActionId,
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  Widget wrap({required AppRole? role, String? organizationId}) {
    const fallbackOrganizationId = 'alpha';
    final resolvedOrganizationId = organizationId ?? fallbackOrganizationId;
    return ChangeNotifierProvider<SessionController>(
      create: (_) => _FakeSession(role: role, organizationId: organizationId),
      child: MaterialApp(
        home: Scaffold(
          body: HazardsManagementScreen(
            repository: HazardRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: resolvedOrganizationId,
            ),
            siteRepository: SiteRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: resolvedOrganizationId,
            ),
            correctiveActionRepository: CorrectiveActionRepository(
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

  group('HazardsManagementScreen (reviewer)', () {
    testWidgets('shows every hazard across the organization', (tester) async {
      await seedOrg('alpha');
      await seedHazard('alpha', 'h1', description: 'Loose scaffolding');
      await seedHazard(
        'alpha',
        'h2',
        description: 'Live wire',
        status: 'closed',
      );

      await tester.pumpWidget(
        wrap(role: AppRole.siteManager, organizationId: 'alpha'),
      );
      await tester.pumpAndSettle();

      // Default filter is "Reported" — only h1 shows until "All" is picked.
      expect(find.text('Loose scaffolding'), findsOneWidget);
      expect(find.text('Live wire'), findsNothing);

      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();

      expect(find.text('Loose scaffolding'), findsOneWidget);
      // The second hazard card can sit below the test screen's edge.
      await tester.scrollUntilVisible(
        find.text('Live wire'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Live wire'), findsOneWidget);
    });

    testWidgets('filtering by status narrows the list', (tester) async {
      await seedOrg('alpha');
      await seedHazard('alpha', 'h1', status: 'reported');
      await seedHazard('alpha', 'h2', status: 'closed');

      await tester.pumpWidget(
        wrap(role: AppRole.siteManager, organizationId: 'alpha'),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Closed'));
      await tester.pumpAndSettle();

      expect(find.byType(Card), findsOneWidget);
    });

    testWidgets('shows an empty state when there are no hazards', (
      tester,
    ) async {
      await seedOrg('alpha');

      await tester.pumpWidget(
        wrap(role: AppRole.siteManager, organizationId: 'alpha'),
      );
      await tester.pumpAndSettle();

      expect(find.text('No hazards have been reported yet.'), findsOneWidget);
    });

    testWidgets(
      'shows a filter-specific empty state when hazards exist but none '
      'match',
      (tester) async {
        await seedOrg('alpha');
        await seedHazard('alpha', 'h1', status: 'closed');

        await tester.pumpWidget(
          wrap(role: AppRole.siteManager, organizationId: 'alpha'),
        );
        await tester.pumpAndSettle();

        // Default filter is "Reported" — the one seeded hazard is closed.
        expect(find.text('No hazards match this filter.'), findsOneWidget);
      },
    );

    testWidgets(
      'a reported hazard offers Acknowledge, Create Corrective Action '
      'and Close Hazard',
      (tester) async {
        await seedOrg('alpha');
        await seedHazard('alpha', 'h1', status: 'reported');

        await tester.pumpWidget(
          wrap(role: AppRole.siteManager, organizationId: 'alpha'),
        );
        await tester.pumpAndSettle();

        expect(find.text('Acknowledge'), findsOneWidget);
        expect(find.text('Create Corrective Action'), findsOneWidget);
        expect(find.text('Close Hazard'), findsOneWidget);
      },
    );

    testWidgets('a closed hazard exposes no mutation actions', (tester) async {
      await seedOrg('alpha');
      await seedHazard('alpha', 'h1', status: 'closed');

      await tester.pumpWidget(
        wrap(role: AppRole.siteManager, organizationId: 'alpha'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();

      expect(find.text('Acknowledge'), findsNothing);
      expect(find.text('Create Corrective Action'), findsNothing);
      expect(find.text('Close Hazard'), findsNothing);
      expect(find.text('Reopen'), findsNothing);
    });

    testWidgets('closing a hazard requires confirmation', (tester) async {
      await seedOrg('alpha');
      await seedHazard('alpha', 'h1', status: 'reported');

      await tester.pumpWidget(
        wrap(role: AppRole.siteManager, organizationId: 'alpha'),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Close Hazard'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close Hazard'));
      await tester.pumpAndSettle();

      expect(find.text('Close Hazard?'), findsOneWidget);
      // Dismiss without confirming — the hazard must remain open.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      final hazardDoc = await firestore
          .doc('organizations/alpha/hazards/h1')
          .get();
      expect(hazardDoc.data()!['status'], 'reported');
    });

    testWidgets('tapping a hazard opens its detail view', (tester) async {
      await seedOrg('alpha');
      await seedHazard(
        'alpha',
        'h1',
        description: 'Blocked fire exit',
        status: 'reported',
      );

      await tester.pumpWidget(
        wrap(role: AppRole.siteManager, organizationId: 'alpha'),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Blocked fire exit'));
      await tester.pumpAndSettle();

      expect(find.text('Blocked fire exit'), findsOneWidget);
      expect(find.text('Reported by'), findsOneWidget);
    });

    testWidgets('detail view shows the linked corrective action reference', (
      tester,
    ) async {
      await seedOrg('alpha');
      await seedHazard(
        'alpha',
        'h1',
        status: 'correctiveActionCreated',
        correctiveActionId: 'action-1',
      );
      await firestore
          .doc('organizations/alpha/corrective_actions/action-1')
          .set({
            'organizationId': 'alpha',
            'projectId': 'project-1',
            'siteId': 'site-1',
            'hazardId': 'h1',
            'title': 'Fix the scaffolding',
            'description': 'Reinforce and inspect',
            'assignedTo': 'worker-2',
            'assignedBy': 'uid-1',
            'dueDate': Timestamp.fromDate(DateTime(2026, 10, 1)),
            'status': 'open',
            'evidenceRequired': false,
            'createdAt': Timestamp.now(),
            'updatedAt': Timestamp.now(),
          });

      await tester.pumpWidget(
        wrap(role: AppRole.siteManager, organizationId: 'alpha'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('A hazard'));
      await tester.pumpAndSettle();

      expect(find.text('Fix the scaffolding'), findsOneWidget);
    });
  });

  group('HazardsManagementScreen (non-reviewer)', () {
    testWidgets('a worker is refused regardless of organization', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(role: AppRole.worker, organizationId: 'alpha'),
      );
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Hazard Management is available to Organization Administrators, '
          'Safety Managers and Foremen.',
        ),
        findsOneWidget,
      );
    });
  });
}
