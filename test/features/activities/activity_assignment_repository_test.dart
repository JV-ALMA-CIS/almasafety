import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/features/activities/data/activity_assignment_repository.dart';

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<void> seedAssignment(
    String orgId,
    String activityId,
    String uid, {
    required String siteId,
  }) async {
    await firestore
        .doc('organizations/$orgId/activities/$activityId/assignments/$uid')
        .set({
      'uid': uid,
      'organizationId': orgId,
      'siteId': siteId,
      'activityId': activityId,
      'assignedAt': Timestamp.now(),
      'assignedBy': 'admin-uid',
    });
  }

  test('watchAssignedWorkers streams only assignments for that activity',
      () async {
    await seedAssignment('org-alpha', 'activity-1', 'worker-1', siteId: 's1');
    await seedAssignment('org-alpha', 'activity-1', 'worker-2', siteId: 's1');
    await seedAssignment('org-alpha', 'activity-2', 'worker-3', siteId: 's1');

    final repository = ActivityAssignmentRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final assignments =
        await repository.watchAssignedWorkers('activity-1').first;

    expect(assignments.map((a) => a.uid).toSet(), {'worker-1', 'worker-2'});
  });

  // fake_cloud_firestore's collectionGroup support is exercised here to
  // confirm the pinned package version actually implements it — if this
  // test starts failing after a package bump, watchAssignmentsForWorker's
  // production behaviour should be re-verified against a real Firestore
  // instance before trusting the fake again.
  test(
    'watchAssignmentsForWorker finds a worker\'s assignments across '
    'every activity via a collection-group query',
    () async {
      await seedAssignment('org-alpha', 'activity-1', 'worker-1', siteId: 's1');
      await seedAssignment('org-alpha', 'activity-2', 'worker-1', siteId: 's2');
      await seedAssignment('org-alpha', 'activity-3', 'worker-2', siteId: 's1');
      await seedAssignment('org-beta', 'activity-9', 'worker-1', siteId: 's9');

      final repository = ActivityAssignmentRepository(
        firestoreService: FirestoreService(firestore: firestore),
        organizationId: 'org-alpha',
      );

      final assignments = await repository
          .watchAssignmentsForWorker('org-alpha', 'worker-1')
          .first;

      expect(
        assignments.map((a) => a.activityId).toSet(),
        {'activity-1', 'activity-2'},
      );
    },
  );
}
