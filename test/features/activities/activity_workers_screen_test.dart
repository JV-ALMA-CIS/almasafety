import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/features/activities/data/activity_assignment_repository.dart';
import 'package:jva_safety/features/activities/data/activity_assignment_service.dart';
import 'package:jva_safety/features/activities/domain/activity.dart';
import 'package:jva_safety/features/activities/presentation/activity_workers_screen.dart';
import 'package:jva_safety/features/authentication/data/account_approval_service.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/organization_user.dart';
import 'package:jva_safety/features/authentication/domain/worker_type.dart';
import 'package:jva_safety/features/organizations/domain/organization.dart';
import 'package:jva_safety/features/organizations/domain/organization_record_status.dart';
import 'package:jva_safety/features/organizations/domain/project.dart';
import 'package:jva_safety/features/organizations/domain/site.dart';

class _FakeApprovalService extends AccountApprovalService {
  _FakeApprovalService({this.users = const []});

  List<OrganizationUser> users;

  @override
  Future<List<OrganizationUser>> listUsers({
    AccountStatus status = AccountStatus.active,
  }) async => users;
}

class _FakeAssignmentService extends ActivityAssignmentService {
  _FakeAssignmentService({this.assignError, this.removeError});

  AppException? assignError;
  AppException? removeError;

  final List<({String uid, String organizationId, String activityId})>
      assignCalls = [];
  final List<({String uid, String organizationId, String activityId})>
      removeCalls = [];

  @override
  Future<void> assignWorkerToActivity({
    required String uid,
    required String organizationId,
    required String activityId,
  }) async {
    final error = assignError;
    if (error != null) throw error;
    assignCalls.add(
      (uid: uid, organizationId: organizationId, activityId: activityId),
    );
  }

  @override
  Future<void> removeWorkerFromActivity({
    required String uid,
    required String organizationId,
    required String activityId,
  }) async {
    final error = removeError;
    if (error != null) throw error;
    removeCalls.add(
      (uid: uid, organizationId: organizationId, activityId: activityId),
    );
  }
}

void main() {
  late FakeFirebaseFirestore firestore;

  const organization = Organization(
    id: 'org-alpha',
    name: 'JV Alma CIS',
    code: 'JV-ALMA-CIS',
    status: OrganizationRecordStatus.active,
  );
  const project = Project(
    id: 'project-1',
    organizationId: 'org-alpha',
    name: 'Rosslyn Tower',
    code: 'ROSS-01',
    status: OrganizationRecordStatus.active,
  );
  const site = Site(
    id: 'site-1',
    organizationId: 'org-alpha',
    projectId: 'project-1',
    name: 'Test Site',
    code: 'ROSS-SITE-01',
    status: OrganizationRecordStatus.active,
  );
  const activity = Activity(
    id: 'activity-1',
    organizationId: 'org-alpha',
    projectId: 'project-1',
    siteId: 'site-1',
    name: 'Roofing',
    code: 'ROOF-01',
    status: OrganizationRecordStatus.active,
  );

  const tomas = OrganizationUser(
    uid: 'O9755kUSpMUZcJWARnsmuCzo8d72',
    name: 'Tomas',
    email: 'tom@example.com',
    accountStatus: AccountStatus.active,
    role: AppRole.foreman,
    workerType: WorkerType.contractor,
    organizationId: 'org-alpha',
    siteIds: ['site-1'],
  );
  const unassignedWorker = OrganizationUser(
    uid: 'worker-2',
    name: 'Peter',
    email: 'peter@example.com',
    accountStatus: AccountStatus.active,
    role: AppRole.worker,
    organizationId: 'org-alpha',
    siteIds: [],
  );

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<void> seedAssignment(String uid) async {
    await firestore
        .doc('organizations/org-alpha/activities/activity-1/assignments/$uid')
        .set({
      'uid': uid,
      'organizationId': 'org-alpha',
      'siteId': 'site-1',
      'activityId': 'activity-1',
      'assignedAt': Timestamp.now(),
      'assignedBy': 'admin-uid',
    });
  }

  Widget wrap({
    List<OrganizationUser> users = const [],
    _FakeAssignmentService? assignmentService,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: ActivityWorkersScreen(
          organization: organization,
          project: project,
          site: site,
          activity: activity,
          assignmentRepository: ActivityAssignmentRepository(
            firestoreService: FirestoreService(firestore: firestore),
            organizationId: organization.id,
          ),
          assignmentService: assignmentService ?? _FakeAssignmentService(),
          approvalService: _FakeApprovalService(users: users),
        ),
      ),
    );
  }

  group('ActivityWorkersScreen (human-readable display)', () {
    testWidgets('shows the assigned worker by name, role and worker type, '
        'not a raw uid', (tester) async {
      await seedAssignment(tomas.uid);

      await tester.pumpWidget(wrap(users: [tomas]));
      await tester.pumpAndSettle();

      expect(find.text('Tomas'), findsOneWidget);
      expect(find.textContaining('Foreman'), findsOneWidget);
      expect(find.textContaining('Contractor'), findsOneWidget);
      expect(find.text(tomas.uid), findsNothing);
    });

    testWidgets('shows the activity/site/organization by name, not a raw '
        'document id', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      expect(find.textContaining('Roofing'), findsOneWidget);
      expect(find.textContaining('Test Site'), findsOneWidget);
      expect(find.textContaining('JV Alma CIS'), findsOneWidget);
      expect(find.text(activity.id), findsNothing);
      expect(find.text(site.id), findsNothing);
      expect(find.text(organization.id), findsNothing);
    });

    testWidgets('the assign picker lists candidates by name, not uid', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(users: [tomas]));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Assign worker'));
      await tester.pumpAndSettle();

      expect(find.text('Tomas'), findsWidgets);
      expect(find.text(tomas.uid), findsNothing);
    });
  });

  group('ActivityWorkersScreen (assignment logic uses real ids)', () {
    testWidgets('selecting a worker by name sends the correct uid/activityId '
        'to the existing callable', (tester) async {
      final service = _FakeAssignmentService();

      await tester.pumpWidget(wrap(users: [tomas], assignmentService: service));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Assign worker'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tomas'));
      await tester.pumpAndSettle();

      expect(service.assignCalls, hasLength(1));
      expect(service.assignCalls.single.uid, tomas.uid);
      expect(service.assignCalls.single.organizationId, 'org-alpha');
      expect(service.assignCalls.single.activityId, 'activity-1');
    });

    testWidgets('removing an assigned worker sends the correct ids', (
      tester,
    ) async {
      await seedAssignment(tomas.uid);
      final service = _FakeAssignmentService();

      await tester.pumpWidget(wrap(users: [tomas], assignmentService: service));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Remove'));
      await tester.pumpAndSettle();

      expect(service.removeCalls, hasLength(1));
      expect(service.removeCalls.single.uid, tomas.uid);
      expect(service.removeCalls.single.activityId, 'activity-1');
    });
  });

  group('ActivityWorkersScreen (site prerequisite)', () {
    testWidgets('a worker without this activity\'s site is not offered as '
        'a candidate', (tester) async {
      await tester.pumpWidget(wrap(users: [unassignedWorker]));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Assign worker'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'No eligible workers. A worker must already have access '
          'to this activity\'s site before they can be assigned.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('an already-assigned worker is not offered again', (
      tester,
    ) async {
      await seedAssignment(tomas.uid);

      await tester.pumpWidget(wrap(users: [tomas]));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Assign worker'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'No eligible workers. A worker must already have access '
          'to this activity\'s site before they can be assigned.',
        ),
        findsOneWidget,
      );
    });
  });

  group('ActivityWorkersScreen (states)', () {
    testWidgets('shows an empty state when nobody is assigned', (
      tester,
    ) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      expect(find.text('No workers assigned yet.'), findsOneWidget);
    });

    testWidgets('surfaces a refused assignment', (tester) async {
      final service = _FakeAssignmentService(
        assignError: const PermissionDeniedException(
          'You do not have permission to do that.',
        ),
      );

      await tester.pumpWidget(wrap(users: [tomas], assignmentService: service));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Assign worker'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tomas'));
      await tester.pumpAndSettle();

      expect(
        find.text('You do not have permission to do that.'),
        findsOneWidget,
      );
    });

    testWidgets('surfaces a refused removal', (tester) async {
      await seedAssignment(tomas.uid);
      final service = _FakeAssignmentService(
        removeError: const PermissionDeniedException(
          'You do not have permission to do that.',
        ),
      );

      await tester.pumpWidget(wrap(users: [tomas], assignmentService: service));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Remove'));
      await tester.pumpAndSettle();

      expect(
        find.text('You do not have permission to do that.'),
        findsOneWidget,
      );
    });
  });
}
