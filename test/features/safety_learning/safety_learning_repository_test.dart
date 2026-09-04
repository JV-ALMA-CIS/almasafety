import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/features/safety_learning/data/safety_learning_repository.dart';

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<void> seedLearning(
    String orgId,
    String id, {
    String status = 'active',
  }) async {
    await firestore.doc('organizations/$orgId/safety_learning/$id').set({
      'organizationId': orgId,
      'title': 'Learning $id',
      'type': 'document',
      'contentReference': 'ref-$id',
      'status': status,
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  test('watchAll streams only the items under this organization', () async {
    await seedLearning('org-alpha', 'l1');
    await seedLearning('org-alpha', 'l2');
    await seedLearning('org-beta', 'l3');

    final repository = SafetyLearningRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final items = await repository.watchAll().first;

    expect(items.map((i) => i.id).toSet(), {'l1', 'l2'});
  });

  test('getById returns null for a missing document', () async {
    final repository = SafetyLearningRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    expect(await repository.getById('missing'), isNull);
  });

  test('organizationId exposes the scope this repository was built with',
      () {
    final repository = SafetyLearningRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    expect(repository.organizationId, 'org-alpha');
  });
}
