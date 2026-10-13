import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/features/activities/data/activity_admin_service.dart';
import 'package:jva_safety/features/activities/data/activity_repository.dart';
import 'package:jva_safety/features/activities/domain/activity.dart';
import 'package:jva_safety/features/authentication/data/account_approval_service.dart';
import 'package:jva_safety/features/authentication/domain/account_status.dart';
import 'package:jva_safety/features/authentication/domain/app_role.dart';
import 'package:jva_safety/features/authentication/domain/organization_user.dart';
import 'package:jva_safety/features/authentication/domain/worker_type.dart';
import 'package:jva_safety/features/safety_learning/data/worker_learning_service.dart';
import 'package:jva_safety/features/safety_learning/domain/worker_learning_record.dart';
import 'package:jva_safety/features/safety_learning/domain/worker_learning_status.dart';
import 'package:jva_safety/features/safety_learning_compliance/data/safety_compliance_repository.dart';

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

/// Stands in for the `getCrewLearningRecords` callable — records are seeded
/// directly (see [seedWorkerLearningRecord]) rather than round-tripping
/// through a fake Cloud Functions transport, matching this test file's
/// existing fake-service convention.
class _FakeWorkerLearningService extends WorkerLearningService {
  final List<WorkerLearningRecord> records = [];

  @override
  Future<List<WorkerLearningRecord>> getCrewLearningRecords({
    required String organizationId,
    required List<String> workerUids,
  }) async {
    final uids = workerUids.toSet();
    return records.where((r) => uids.contains(r.workerUid)).toList();
  }
}

void main() {
  late FakeFirebaseFirestore firestore;
  late _FakeWorkerLearningService workerLearningService;

  setUp(() {
    firestore = FakeFirebaseFirestore();
    workerLearningService = _FakeWorkerLearningService();
  });

  Future<void> seedActivity(
    String id, {
    String siteId = 'site-1',
    String name = 'Roofing',
    String status = 'active',
  }) {
    return firestore.doc('organizations/org-alpha/activities/$id').set({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': siteId,
      'name': name,
      'code': 'CODE-$id',
      'status': status,
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  Future<void> seedAssignment(String activityId, String uid, String siteId) {
    return firestore
        .doc('organizations/org-alpha/activities/$activityId/assignments/$uid')
        .set({
          'uid': uid,
          'organizationId': 'org-alpha',
          'siteId': siteId,
          'activityId': activityId,
          'assignedAt': Timestamp.now(),
          'assignedBy': 'foreman-a',
        });
  }

  Future<void> seedSafetyLearning(String id, {String title = 'Learning'}) {
    return firestore.doc('organizations/org-alpha/safety_learning/$id').set({
      'organizationId': 'org-alpha',
      'title': title,
      'type': 'document',
      'contentReference': 'ref-$id',
      'status': 'active',
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  Future<void> seedSafetyRequirement(
    String id, {
    required List<String> requiredLearningIds,
    String? siteId,
    String? activityId,
  }) {
    return firestore
        .doc('organizations/org-alpha/safety_requirements/$id')
        .set({
          'organizationId': 'org-alpha',
          'name': 'Requirement $id',
          'category': 'General',
          'risk': 'medium',
          'requiredLearningIds': requiredLearningIds,
          'status': 'active',
          'siteId': ?siteId,
          'activityId': ?activityId,
          'createdAt': Timestamp.now(),
          'updatedAt': Timestamp.now(),
        });
  }

  void seedWorkerLearningRecord(
    String workerUid,
    String learningId, {
    required String status,
  }) {
    workerLearningService.records.add(
      WorkerLearningRecord(
        id: '${workerUid}_$learningId',
        workerUid: workerUid,
        organizationId: 'org-alpha',
        learningId: learningId,
        status: WorkerLearningStatus.tryFromId(status)!,
        completedAt: status == 'completed' ? DateTime.now() : null,
      ),
    );
  }

  SafetyComplianceRepository repositoryWith(List<OrganizationUser> users) {
    final firestoreService = FirestoreService(firestore: firestore);
    return SafetyComplianceRepository(
      firestoreService: firestoreService,
      organizationId: 'org-alpha',
      accountApprovalService: _FakeApprovalService(users: users),
      workerLearningService: workerLearningService,
      activityAdminService: _FakeActivityAdminService(
        ActivityRepository(
          firestoreService: firestoreService,
          organizationId: 'org-alpha',
        ),
      ),
    );
  }

  const worker = OrganizationUser(
    uid: 'worker-a',
    name: 'Alex Worker',
    email: 'alex@example.com',
    accountStatus: AccountStatus.active,
    role: AppRole.worker,
    workerType: WorkerType.jvaEmployee,
  );

  test('resolves an org-wide requirement for a worker assigned to the '
      "site's activity", () async {
    await seedActivity('activity-1');
    await seedAssignment('activity-1', 'worker-a', 'site-1');
    await seedSafetyLearning('l1', title: 'Fire Safety');
    await seedSafetyRequirement('r1', requiredLearningIds: ['l1']);

    final summaries = await repositoryWith([
      worker,
    ]).buildSiteCompliance('site-1');

    expect(summaries, hasLength(1));
    expect(summaries.first.activityName, 'Roofing');
    expect(summaries.first.rows, hasLength(1));
    final row = summaries.first.rows.first;
    expect(row.workerUid, 'worker-a');
    expect(row.workerName, 'Alex Worker');
    expect(row.requiredCount, 1);
    expect(row.completedCount, 0);
    expect(row.outstandingCount, 1);
    expect(row.isReady, isFalse);
  });

  test('a worker who completes the required item becomes Ready', () async {
    await seedActivity('activity-1');
    await seedAssignment('activity-1', 'worker-a', 'site-1');
    await seedSafetyLearning('l1', title: 'Fire Safety');
    await seedSafetyRequirement('r1', requiredLearningIds: ['l1']);
    seedWorkerLearningRecord('worker-a', 'l1', status: 'completed');

    final summaries = await repositoryWith([
      worker,
    ]).buildSiteCompliance('site-1');

    final row = summaries.first.rows.first;
    expect(row.completedCount, 1);
    expect(row.outstandingCount, 0);
    expect(row.isReady, isTrue);
    expect(row.completedLearning.single.title, 'Fire Safety');
    expect(row.completedAtByLearningId['l1'], isNotNull);
  });

  test('a worker with nothing required is vacuously Ready', () async {
    await seedActivity('activity-1');
    await seedAssignment('activity-1', 'worker-a', 'site-1');

    final summaries = await repositoryWith([
      worker,
    ]).buildSiteCompliance('site-1');

    final row = summaries.first.rows.first;
    expect(row.requiredCount, 0);
    expect(row.isReady, isTrue);
  });

  test(
    'a site-scoped requirement for a DIFFERENT site does not apply here',
    () async {
      await seedActivity('activity-1');
      await seedAssignment('activity-1', 'worker-a', 'site-1');
      await seedSafetyLearning('l1');
      await seedSafetyRequirement(
        'r1',
        requiredLearningIds: ['l1'],
        siteId: 'site-2',
      );

      final summaries = await repositoryWith([
        worker,
      ]).buildSiteCompliance('site-1');

      expect(summaries.first.rows.first.requiredCount, 0);
    },
  );

  test('an activity-scoped requirement resolves only for the matching '
      'activity', () async {
    await seedActivity('activity-1');
    await seedAssignment('activity-1', 'worker-a', 'site-1');
    await seedSafetyLearning('l1', title: 'Working at Height');
    await seedSafetyRequirement(
      'r1',
      requiredLearningIds: ['l1'],
      activityId: 'activity-1',
    );

    final summaries = await repositoryWith([
      worker,
    ]).buildSiteCompliance('site-1');

    expect(summaries.first.rows.first.requiredCount, 1);
  });

  test(
    'excludes a worker assigned to an activity at a DIFFERENT site',
    () async {
      await seedActivity('activity-1', siteId: 'site-1');
      await seedActivity('activity-2', siteId: 'site-2', name: 'Electrical');
      await seedAssignment('activity-1', 'worker-a', 'site-1');
      const otherWorker = OrganizationUser(
        uid: 'worker-b',
        name: 'Blair Worker',
        email: 'blair@example.com',
        accountStatus: AccountStatus.active,
      );
      await seedAssignment('activity-2', 'worker-b', 'site-2');

      final summaries = await repositoryWith([
        worker,
        otherWorker,
      ]).buildSiteCompliance('site-1');

      // Only activity-1 (site-1's own activity) is included, and only
      // worker-a (assigned there) appears — worker-b's site-2 assignment
      // never surfaces under site-1's compliance view.
      expect(summaries, hasLength(1));
      expect(summaries.first.activityId, 'activity-1');
      expect(summaries.first.rows.map((r) => r.workerUid), ['worker-a']);
    },
  );

  test('excludes an inactive activity from the site view', () async {
    await seedActivity('activity-1', status: 'inactive');
    await seedAssignment('activity-1', 'worker-a', 'site-1');

    final summaries = await repositoryWith([
      worker,
    ]).buildSiteCompliance('site-1');

    expect(summaries, isEmpty);
  });

  test('an activity with no assigned workers still appears, with zero '
      'workers', () async {
    await seedActivity('activity-1');

    final summaries = await repositoryWith(
      const [],
    ).buildSiteCompliance('site-1');

    expect(summaries, hasLength(1));
    expect(summaries.first.workerCount, 0);
    expect(summaries.first.readyCount, 0);
    expect(summaries.first.notReadyCount, 0);
  });

  test('ActivityComplianceSummary aggregates Ready/Not Ready counts '
      'correctly across several workers', () async {
    await seedActivity('activity-1');
    await seedAssignment('activity-1', 'worker-a', 'site-1');
    const readyWorker = OrganizationUser(
      uid: 'worker-b',
      name: 'Blair Worker',
      email: 'blair@example.com',
      accountStatus: AccountStatus.active,
    );
    await seedAssignment('activity-1', 'worker-b', 'site-1');
    await seedSafetyLearning('l1');
    await seedSafetyRequirement('r1', requiredLearningIds: ['l1']);
    seedWorkerLearningRecord('worker-b', 'l1', status: 'completed');

    final summaries = await repositoryWith([
      worker,
      readyWorker,
    ]).buildSiteCompliance('site-1');

    final summary = summaries.first;
    expect(summary.workerCount, 2);
    expect(summary.readyCount, 1);
    expect(summary.notReadyCount, 1);
  });

  test(
    'an inProgress (not completed) record still counts as outstanding',
    () async {
      await seedActivity('activity-1');
      await seedAssignment('activity-1', 'worker-a', 'site-1');
      await seedSafetyLearning('l1');
      await seedSafetyRequirement('r1', requiredLearningIds: ['l1']);
      seedWorkerLearningRecord('worker-a', 'l1', status: 'inProgress');

      final summaries = await repositoryWith([
        worker,
      ]).buildSiteCompliance('site-1');

      final row = summaries.first.rows.first;
      expect(row.completedCount, 0);
      expect(row.outstandingCount, 1);
      expect(row.isReady, isFalse);
    },
  );
}
