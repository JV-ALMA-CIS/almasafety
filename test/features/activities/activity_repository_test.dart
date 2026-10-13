import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/features/activities/data/activity_repository.dart';

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<void> seedActivity(
    String orgId,
    String id, {
    required String siteId,
  }) async {
    await firestore.doc('organizations/$orgId/activities/$id').set({
      'organizationId': orgId,
      'projectId': 'p1',
      'siteId': siteId,
      'name': 'Activity $id',
      'code': 'CODE-$id',
      'status': 'active',
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  test(
    'watchAll streams only the activities under this organization',
    () async {
      await seedActivity('org-alpha', 'a1', siteId: 's1');
      await seedActivity('org-alpha', 'a2', siteId: 's2');
      await seedActivity('org-beta', 'a3', siteId: 's1');

      final repository = ActivityRepository(
        firestoreService: FirestoreService(firestore: firestore),
        organizationId: 'org-alpha',
      );

      final activities = await repository.watchAll().first;

      expect(activities.map((a) => a.id).toSet(), {'a1', 'a2'});
    },
  );

  test('watchBySite narrows to one site within the organization', () async {
    await seedActivity('org-alpha', 'a1', siteId: 's1');
    await seedActivity('org-alpha', 'a2', siteId: 's2');
    await seedActivity('org-alpha', 'a3', siteId: 's1');

    final repository = ActivityRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final activities = await repository.watchBySite('s1').first;

    expect(activities.map((a) => a.id).toSet(), {'a1', 'a3'});
    expect(activities.every((a) => a.siteId == 's1'), isTrue);
  });

  test('organizationId exposes the scope this repository was built with', () {
    final repository = ActivityRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    expect(repository.organizationId, 'org-alpha');
  });
}
