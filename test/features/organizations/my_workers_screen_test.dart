import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/core/services/session_controller.dart';
import 'package:jva_safety/features/activities/data/activity_admin_service.dart';
import 'package:jva_safety/features/activities/data/activity_assignment_repository.dart';
import 'package:jva_safety/features/activities/domain/activity.dart';
import 'package:jva_safety/features/authentication/data/account_approval_service.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/membership.dart';
import 'package:jva_safety/features/authentication/domain/organization_user.dart';
import 'package:jva_safety/features/authentication/domain/user_profile.dart';
import 'package:jva_safety/features/authentication/domain/worker_type.dart';
import 'package:jva_safety/features/organizations/data/organization_repository.dart';
import 'package:jva_safety/features/organizations/data/project_repository.dart';
import 'package:jva_safety/features/organizations/data/site_repository.dart';
import 'package:jva_safety/features/organizations/domain/organization_record_status.dart';
import 'package:jva_safety/features/organizations/presentation/my_workers_screen.dart';

/// A fake user-listing service, subclassing the real one rather than mocking
/// — the repo's established pattern (see site_workers_screen_test.dart's
/// `_FakeApprovalService`).
class _FakeApprovalService extends AccountApprovalService {
  _FakeApprovalService({this.users = const [], this.listError});

  List<OrganizationUser> users;
  AppException? listError;

  @override
  Future<List<OrganizationUser>> listUsers({
    AccountStatus status = AccountStatus.active,
    String? organizationId,
  }) async {
    final error = listError;
    if (error != null) throw error;
    return users;
  }
}

/// Stands in for the `getSiteActivities` callable — returns [activities]
/// filtered to the requested [siteId], matching the real callable's own
/// scoping. Most tests in this file don't need real activity data, only
/// that the call succeeds instead of reaching for a real, unconfigured
/// Cloud Functions transport — the "assign worker" drill-down test below
/// is the one that actually seeds [activities].
class _FakeActivityAdminService extends ActivityAdminService {
  _FakeActivityAdminService({this.activities = const []});

  final List<Activity> activities;

  @override
  Future<List<Activity>> getSiteActivities({
    required String organizationId,
    required String siteId,
  }) async => activities.where((a) => a.siteId == siteId).toList();
}

class _FakeSession extends SessionController {
  _FakeSession({
    required AppRole? role,
    String? organizationId = 'org-alpha',
    List<String> siteIds = const [],
  }) : _profile = UserProfile(
         uid: 'foreman-uid',
         name: 'Foreman',
         email: 'foreman@example.com',
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

  @override
  Membership? membershipFor(String organizationId) =>
      _membership?.organizationId == organizationId ? _membership : null;
}

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<void> seedSite(String id, {String name = 'Site'}) async {
    await firestore.doc('organizations/org-alpha/sites/$id').set({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'name': name,
      'code': 'CODE-$id',
      'status': 'active',
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  Future<void> seedOrganization() async {
    await firestore.doc('organizations/org-alpha').set({
      'name': 'JV Alma CIS',
      'code': 'CODE-org-alpha',
      'status': 'active',
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  Future<void> seedProject() async {
    await firestore.doc('organizations/org-alpha/projects/project-1').set({
      'organizationId': 'org-alpha',
      'name': 'Project One',
      'code': 'CODE-project-1',
      'status': 'active',
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  OrganizationUser worker(
    String uid, {
    String name = 'Worker',
    List<String> siteIds = const ['site-1'],
    WorkerType? workerType = WorkerType.subcontractor,
  }) {
    return OrganizationUser(
      uid: uid,
      name: name,
      email: '$uid@example.com',
      accountStatus: AccountStatus.active,
      role: AppRole.worker,
      workerType: workerType,
      organizationId: 'org-alpha',
      siteIds: siteIds,
    );
  }

  Widget wrap(
    _FakeApprovalService service, {
    AppRole? role = AppRole.foreman,
    String? organizationId = 'org-alpha',
    List<String> siteIds = const ['site-1'],
    List<Activity> activities = const [],
  }) {
    return ChangeNotifierProvider<SessionController>(
      create: (_) => _FakeSession(
        role: role,
        organizationId: organizationId,
        siteIds: siteIds,
      ),
      child: MaterialApp(
        home: Scaffold(
          body: MyWorkersScreen(
            approvalService: service,
            siteRepositoryFor: (orgId) => SiteRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: orgId,
            ),
            activityAdminService: _FakeActivityAdminService(
              activities: activities,
            ),
            organizationRepository: OrganizationRepository(
              firestoreService: FirestoreService(firestore: firestore),
            ),
            projectRepository: (orgId) => ProjectRepository(
              firestoreService: FirestoreService(firestore: firestore),
              organizationId: orgId,
            ),
            activityAssignmentRepositoryFor: (orgId) =>
                ActivityAssignmentRepository(
                  firestoreService: FirestoreService(firestore: firestore),
                  organizationId: orgId,
                ),
          ),
        ),
      ),
    );
  }

  group('MyWorkersScreen (authorization)', () {
    testWidgets('a Foreman with no assigned site sees a clear message, not an '
        'empty list — regression test for the underlying bug this screen '
        'exists to surface: a Foreman approved with no site cannot use '
        'Daily Safety Meetings either', (tester) async {
      await tester.pumpWidget(wrap(_FakeApprovalService(), siteIds: const []));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'You have not been assigned to a site yet. Ask your Site '
          'Manager to assign you one from Operations → your project → '
          'your site → Workforce.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a Site Manager sees the same permission message', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(_FakeApprovalService(), role: AppRole.siteManager),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('My Workers is available to a Foreman assigned to a site.'),
        findsOneWidget,
      );
    });

    testWidgets('a Worker sees the same permission message', (tester) async {
      await tester.pumpWidget(
        wrap(_FakeApprovalService(), role: AppRole.worker),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('My Workers is available to a Foreman assigned to a site.'),
        findsOneWidget,
      );
    });
  });

  group('MyWorkersScreen (list content)', () {
    testWidgets('shows a worker assigned to the Foreman\'s own site', (
      tester,
    ) async {
      await seedSite('site-1', name: 'North Yard');
      final service = _FakeApprovalService(
        users: [worker('worker-1', name: 'Alice')],
      );

      await tester.pumpWidget(wrap(service));
      await tester.pumpAndSettle();

      expect(find.text('Alice'), findsOneWidget);
      expect(find.textContaining('North Yard'), findsOneWidget);
    });

    testWidgets('does not show a worker assigned to a DIFFERENT site than the '
        'Foreman\'s own', (tester) async {
      final service = _FakeApprovalService(
        users: [
          worker('worker-1', name: 'Alice', siteIds: const ['site-2']),
        ],
      );

      await tester.pumpWidget(wrap(service));
      await tester.pumpAndSettle();

      expect(find.text('Alice'), findsNothing);
    });

    testWidgets('does not show a non-Worker role (e.g. another Foreman)', (
      tester,
    ) async {
      final service = _FakeApprovalService(
        users: [
          OrganizationUser(
            uid: 'foreman-2',
            name: 'Other Foreman',
            email: 'other@example.com',
            accountStatus: AccountStatus.active,
            role: AppRole.foreman,
            organizationId: 'org-alpha',
            siteIds: const ['site-1'],
          ),
        ],
      );

      await tester.pumpWidget(wrap(service));
      await tester.pumpAndSettle();

      expect(find.text('Other Foreman'), findsNothing);
    });

    testWidgets('shows an empty state when no workers are assigned', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(_FakeApprovalService()));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('No workers are assigned to your site'),
        findsOneWidget,
      );
    });
  });

  group('MyWorkersScreen (assigning a worker to an activity)', () {
    testWidgets(
      'shows the Foreman\'s own site\'s activities, and tapping one opens '
      'ActivityWorkersScreen — the actual assign/remove UI',
      (tester) async {
        await seedOrganization();
        await seedProject();
        await seedSite('site-1', name: 'North Yard');
        const activity = Activity(
          id: 'activity-1',
          organizationId: 'org-alpha',
          projectId: 'project-1',
          siteId: 'site-1',
          name: 'Roofing',
          code: 'CODE-activity-1',
          status: OrganizationRecordStatus.active,
        );

        await tester.pumpWidget(
          wrap(_FakeApprovalService(), activities: const [activity]),
        );
        await tester.pumpAndSettle();

        expect(find.text('Roofing'), findsOneWidget);
        expect(find.textContaining('North Yard'), findsWidgets);

        await tester.tap(find.text('Roofing'));
        await tester.pumpAndSettle();

        // ActivityWorkersScreen's own header — proves the Foreman actually
        // reached the assign/remove screen, not just a static card.
        expect(find.text('Assigned Workers'), findsOneWidget);
        expect(find.byTooltip('Assign worker'), findsOneWidget);
      },
    );

    testWidgets(
      'a Foreman with no active activities at their site sees a clear '
      'message instead of an empty gap',
      (tester) async {
        await tester.pumpWidget(wrap(_FakeApprovalService()));
        await tester.pumpAndSettle();

        expect(
          find.text('No active activities are recorded at your site(s) yet.'),
          findsOneWidget,
        );
      },
    );
  });

  group('MyWorkersScreen (list content, continued)', () {
    testWidgets('surfaces a load failure without crashing', (tester) async {
      final service = _FakeApprovalService(
        listError: const DataException('Could not load workers.'),
      );

      await tester.pumpWidget(wrap(service));
      await tester.pumpAndSettle();

      expect(find.text('Could not load workers.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
