import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/activities/data/activity_admin_service.dart';
import 'package:jva_safety/features/activities/data/activity_repository.dart';
import 'package:jva_safety/features/activities/domain/activity.dart';
import 'package:jva_safety/features/authentication/data/account_approval_service.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/membership.dart';
import 'package:jva_safety/features/authentication/domain/organization_user.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/organizations/data/organization_repository.dart';
import 'package:jva_safety/features/organizations/data/site_repository.dart';
import 'package:jva_safety/features/safety_learning/data/worker_learning_service.dart';
import 'package:jva_safety/features/safety_learning/domain/worker_learning_record.dart';
import 'package:jva_safety/features/safety_learning_compliance/data/safety_compliance_repository.dart';
import 'package:jva_safety/features/safety_learning_compliance/presentation/safety_learning_compliance_screen.dart';

class _FakeApprovalService extends AccountApprovalService {
  _FakeApprovalService({this.users = const []});

  List<OrganizationUser> users;

  @override
  Future<List<OrganizationUser>> listUsers({
    AccountStatus status = AccountStatus.active,
    String? organizationId,
  }) async => users;
}

/// Stands in for the `getSiteActivities` callable — reads through the same
/// fake Firestore via [ActivityRepository.watchBySite], which is fine in
/// tests since `FakeFirebaseFirestore` does not enforce security rules.
class _FakeActivityAdminService extends ActivityAdminService {
  _FakeActivityAdminService(this._repository);

  final ActivityRepository _repository;

  @override
  Future<List<Activity>> getSiteActivities({
    required String organizationId,
    required String siteId,
  }) => _repository.watchBySite(siteId).first;
}

/// Stands in for the `getCrewLearningRecords` callable — no test in this
/// file needs completion data, only that the call succeeds instead of
/// reaching for a real, unconfigured Cloud Functions transport.
class _FakeWorkerLearningService extends WorkerLearningService {
  @override
  Future<List<WorkerLearningRecord>> getCrewLearningRecords({
    required String organizationId,
    required List<String> workerUids,
  }) async => const [];
}

class _FakeSession extends SessionController {
  _FakeSession({
    required AppRole? role,
    String? organizationId,
    List<String> siteIds = const [],
  }) : _profile = UserProfile(
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
               siteIds: siteIds,
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

  Future<void> seedOrg(String id) {
    return firestore.doc('organizations/$id').set({
      'name': 'Org $id',
      'code': 'CODE-$id',
      'status': 'active',
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  Future<void> seedSite(String orgId, String id, {String name = 'Site A'}) {
    return firestore.doc('organizations/$orgId/sites/$id').set({
      'organizationId': orgId,
      'projectId': 'project-1',
      'name': name,
      'code': 'CODE-$id',
      'status': 'active',
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  Future<void> seedActivity(
    String orgId,
    String id, {
    String siteId = 'site-1',
  }) {
    return firestore.doc('organizations/$orgId/activities/$id').set({
      'organizationId': orgId,
      'projectId': 'project-1',
      'siteId': siteId,
      'name': 'Roofing',
      'code': 'CODE-$id',
      'status': 'active',
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  Future<void> seedAssignment(
    String orgId,
    String activityId,
    String uid,
    String siteId,
  ) {
    return firestore
        .doc('organizations/$orgId/activities/$activityId/assignments/$uid')
        .set({
          'uid': uid,
          'organizationId': orgId,
          'siteId': siteId,
          'activityId': activityId,
          'assignedAt': Timestamp.now(),
          'assignedBy': 'foreman-a',
        });
  }

  Widget wrap({
    required AppRole? role,
    String? organizationId,
    List<OrganizationUser> members = const [],
    List<String> siteIds = const [],
  }) {
    // Built even when `organizationId` starts null (an Admin with no
    // membership): OrganizationScopeSelector now auto-selects a sole
    // seeded organization rather than leaving the picker showing forever,
    // so the screen may resolve an organization id itself once the fake
    // Firestore stream settles — these repositories must be fake-backed
    // for that case too, not only when the caller already knows the id.
    const fallbackOrganizationId = 'org-alpha';
    final resolvedOrganizationId = organizationId ?? fallbackOrganizationId;
    return ChangeNotifierProvider<SessionController>(
      create: (_) => _FakeSession(
        role: role,
        organizationId: organizationId,
        siteIds: siteIds,
      ),
      child: MaterialApp(
        home: Scaffold(
          body: SafetyLearningComplianceScreen(
            repository: SafetyComplianceRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: resolvedOrganizationId,
              accountApprovalService: _FakeApprovalService(users: members),
              workerLearningService: _FakeWorkerLearningService(),
              activityAdminService: _FakeActivityAdminService(
                ActivityRepository(
                  firestoreService: FirestoreService(firestore: firestore),
                  organizationId: resolvedOrganizationId,
                ),
              ),
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

  group('SafetyLearningComplianceScreen (authorization)', () {
    testWidgets('a worker is refused', (tester) async {
      await tester.pumpWidget(
        wrap(role: AppRole.worker, organizationId: 'org-alpha'),
      );
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Safety Learning compliance is available to Admins, Site '
          'Managers and Foremen.',
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'a foreman sees only their own assigned site(s), scoped to their '
      'crew readiness',
      (tester) async {
        await seedSite('org-alpha', 'site-1', name: 'Rosslyn');
        await seedSite('org-alpha', 'site-2', name: 'Ambassadors');

        await tester.pumpWidget(
          wrap(
            role: AppRole.foreman,
            organizationId: 'org-alpha',
            siteIds: ['site-1'],
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.text(
            'Safety Learning compliance is available to Admins, Site '
            'Managers and Foremen.',
          ),
          findsNothing,
        );
        // No org picker for a Foreman — they act within their own membership,
        // never a cross-organization oversight choice.
        expect(find.text('Organization'), findsNothing);
        expect(find.text('Rosslyn'), findsOneWidget);
        expect(find.text('Ambassadors'), findsNothing);
      },
    );

    testWidgets(
      'a foreman with no site assignment yet sees a scoped empty state, '
      'not "add a site"',
      (tester) async {
        await seedSite('org-alpha', 'site-1');

        await tester.pumpWidget(
          wrap(role: AppRole.foreman, organizationId: 'org-alpha'),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('You are not yet assigned to a site.'),
          findsOneWidget,
        );
      },
    );

    testWidgets('a Site Manager sees the site list directly', (tester) async {
      await seedSite('org-alpha', 'site-1');

      await tester.pumpWidget(
        wrap(role: AppRole.siteManager, organizationId: 'org-alpha'),
      );
      await tester.pumpAndSettle();

      expect(find.text('Safety Learning Compliance'), findsOneWidget);
      expect(find.text('Site A'), findsOneWidget);
    });

    testWidgets('an Admin with one organization is taken straight to its site '
        'list — nothing to pick', (tester) async {
      await seedOrg('org-alpha');
      await seedSite('org-alpha', 'site-1');

      await tester.pumpWidget(wrap(role: AppRole.admin, organizationId: null));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Safety Learning compliance is available to Admins and Site '
          'Managers.',
        ),
        findsNothing,
      );
      // The sole organization is auto-selected — see
      // OrganizationScopeSelector's own doc comment — so the picker never
      // appears and the Admin lands directly on that organization's sites.
      expect(find.text('Organization'), findsNothing);
      expect(find.text('Safety Learning Compliance'), findsOneWidget);
      expect(find.text('Site A'), findsOneWidget);
    });

    testWidgets('an Admin with two organizations sees a real picker instead of '
        'being blocked', (tester) async {
      await seedOrg('org-alpha');
      await seedOrg('org-beta');

      await tester.pumpWidget(wrap(role: AppRole.admin, organizationId: null));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Safety Learning compliance is available to Admins and Site '
          'Managers.',
        ),
        findsNothing,
      );
      expect(find.text('Organization'), findsOneWidget);
    });
  });

  group('SafetyLearningComplianceScreen (Site -> Activity -> Workers)', () {
    testWidgets('drills from site to activity summary to worker detail', (
      tester,
    ) async {
      await seedSite('org-alpha', 'site-1');
      await seedActivity('org-alpha', 'activity-1');
      await seedAssignment('org-alpha', 'activity-1', 'worker-a', 'site-1');
      const worker = OrganizationUser(
        uid: 'worker-a',
        name: 'Alex Worker',
        email: 'alex@example.com',
        accountStatus: AccountStatus.active,
      );

      await tester.pumpWidget(
        wrap(
          role: AppRole.siteManager,
          organizationId: 'org-alpha',
          members: [worker],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Site A'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Roofing'), findsOneWidget);
      expect(find.text('1 worker · 1 Ready · 0 Not Ready'), findsOneWidget);

      await tester.tap(find.textContaining('Roofing'));
      await tester.pumpAndSettle();

      expect(find.text('Alex Worker'), findsOneWidget);
      expect(find.text('Ready'), findsOneWidget);

      await tester.tap(find.text('Alex Worker'));
      await tester.pumpAndSettle();

      expect(find.text('Outstanding (0)'), findsOneWidget);
      expect(find.text('Nothing outstanding.'), findsOneWidget);
    });
  });
}
