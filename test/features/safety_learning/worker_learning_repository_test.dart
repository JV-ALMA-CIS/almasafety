import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/features/safety_learning/data/worker_learning_repository.dart';

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<void> seedRecord(
    String orgId,
    String workerUid,
    String learningId, {
    String status = 'assigned',
  }) async {
    await firestore
        .doc(
          'organizations/$orgId/worker_learning_records/'
          '${workerUid}_$learningId',
        )
        .set({
      'workerUid': workerUid,
      'organizationId': orgId,
      'learningId': learningId,
      'status': status,
      'assignedAt': Timestamp.now(),
    });
  }

  test('watchMine streams only the calling worker\'s records', () async {
    await seedRecord('org-alpha', 'worker-1', 'l1');
    await seedRecord('org-alpha', 'worker-1', 'l2');
    await seedRecord('org-alpha', 'worker-2', 'l1');

    final repository = WorkerLearningRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final records = await repository.watchMine('worker-1').first;

    expect(records.map((r) => r.learningId).toSet(), {'l1', 'l2'});
    expect(records.every((r) => r.workerUid == 'worker-1'), isTrue);
  });

  test('watchForOrganization streams every record in this organization',
      () async {
    await seedRecord('org-alpha', 'worker-1', 'l1');
    await seedRecord('org-alpha', 'worker-2', 'l1');

    final repository = WorkerLearningRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final records = await repository.watchForOrganization().first;

    expect(records.map((r) => r.workerUid).toSet(), {'worker-1', 'worker-2'});
  });

  test('records from another organization never leak into either query',
      () async {
    await seedRecord('org-alpha', 'worker-1', 'l1');
    await seedRecord('org-beta', 'worker-1', 'l1');

    final repository = WorkerLearningRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final mine = await repository.watchMine('worker-1').first;
    final forOrg = await repository.watchForOrganization().first;

    expect(mine, hasLength(1));
    expect(forOrg, hasLength(1));
  });

  test('organizationId exposes the scope this repository was built with',
      () {
    final repository = WorkerLearningRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    expect(repository.organizationId, 'org-alpha');
  });
}
