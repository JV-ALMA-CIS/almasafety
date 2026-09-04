import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/features/safety_requirements/data/safety_requirement_repository.dart';

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<void> seedRequirement(
    String orgId,
    String id, {
    required List<String> requiredLearningIds,
    String status = 'active',
  }) async {
    await firestore.doc('organizations/$orgId/safety_requirements/$id').set({
      'organizationId': orgId,
      'name': 'Requirement $id',
      'category': 'General',
      'risk': 'medium',
      'requiredLearningIds': requiredLearningIds,
      'status': status,
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

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

  test('watchAll streams only the requirements under this organization',
      () async {
    await seedRequirement('org-alpha', 'r1', requiredLearningIds: []);
    await seedRequirement('org-beta', 'r2', requiredLearningIds: []);

    final repository = SafetyRequirementRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final requirements = await repository.watchAll().first;

    expect(requirements.map((r) => r.id).toSet(), {'r1'});
  });

  test(
      'watchResolvedRequiredLearning de-duplicates across overlapping '
      'requirements', () async {
    await seedLearning('org-alpha', 'l1');
    await seedLearning('org-alpha', 'l2');
    await seedRequirement(
      'org-alpha',
      'r1',
      requiredLearningIds: ['l1', 'l2'],
    );
    await seedRequirement(
      'org-alpha',
      'r2',
      requiredLearningIds: ['l1'],
    );

    final repository = SafetyRequirementRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final resolved = await repository.watchResolvedRequiredLearning().first;

    expect(resolved.map((l) => l.id).toSet(), {'l1', 'l2'});
  });

  test('watchResolvedRequiredLearning excludes an inactive learning item',
      () async {
    await seedLearning('org-alpha', 'l1');
    await seedLearning('org-alpha', 'l2', status: 'inactive');
    await seedRequirement(
      'org-alpha',
      'r1',
      requiredLearningIds: ['l1', 'l2'],
    );

    final repository = SafetyRequirementRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final resolved = await repository.watchResolvedRequiredLearning().first;

    expect(resolved.map((l) => l.id).toSet(), {'l1'});
  });

  test(
      "watchResolvedRequiredLearning excludes an inactive requirement's "
      'contribution', () async {
    await seedLearning('org-alpha', 'l1');
    await seedLearning('org-alpha', 'l2');
    await seedRequirement(
      'org-alpha',
      'r1',
      requiredLearningIds: ['l1'],
    );
    await seedRequirement(
      'org-alpha',
      'r2',
      requiredLearningIds: ['l2'],
      status: 'inactive',
    );

    final repository = SafetyRequirementRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final resolved = await repository.watchResolvedRequiredLearning().first;

    expect(resolved.map((l) => l.id).toSet(), {'l1'});
  });

  test('watchResolvedRequiredLearning is empty when nothing is required',
      () async {
    final repository = SafetyRequirementRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final resolved = await repository.watchResolvedRequiredLearning().first;

    expect(resolved, isEmpty);
  });
}
