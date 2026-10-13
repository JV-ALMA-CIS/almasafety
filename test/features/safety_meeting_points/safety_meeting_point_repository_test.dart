import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/features/safety_meeting_points/data/safety_meeting_point_repository.dart';

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<void> seedPoint(
    String orgId,
    String id, {
    String status = 'active',
    List<String> applicableActivities = const [],
    List<String> applicableRisks = const [],
  }) async {
    await firestore.doc('organizations/$orgId/safety_meeting_points/$id').set({
      'organizationId': orgId,
      'title': 'Meeting Point $id',
      'category': 'General',
      'applicableActivities': applicableActivities,
      'applicableRisks': applicableRisks,
      'status': status,
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  test('watchAll streams only the items under this organization', () async {
    await seedPoint('org-alpha', 'p1');
    await seedPoint('org-alpha', 'p2');
    await seedPoint('org-beta', 'p3');

    final repository = SafetyMeetingPointRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final items = await repository.watchAll().first;

    expect(items.map((i) => i.id).toSet(), {'p1', 'p2'});
  });

  test('watchActive excludes inactive items within the organization', () async {
    await seedPoint('org-alpha', 'p1');
    await seedPoint('org-alpha', 'p2', status: 'inactive');

    final repository = SafetyMeetingPointRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final items = await repository.watchActive().first;

    expect(items.map((i) => i.id).toSet(), {'p1'});
  });

  test('watchActive excludes another organization even when active', () async {
    await seedPoint('org-alpha', 'p1');
    await seedPoint('org-beta', 'p2');

    final repository = SafetyMeetingPointRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final items = await repository.watchActive().first;

    expect(items.map((i) => i.id).toSet(), {'p1'});
  });

  test('watchActive filters by activityId, treating an empty list as '
      'universal', () async {
    await seedPoint(
      'org-alpha',
      'specific',
      applicableActivities: ['activity-1'],
    );
    await seedPoint('org-alpha', 'other', applicableActivities: ['activity-2']);
    await seedPoint('org-alpha', 'universal');

    final repository = SafetyMeetingPointRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final items = await repository.watchActive(activityId: 'activity-1').first;

    expect(items.map((i) => i.id).toSet(), {'specific', 'universal'});
  });

  test(
    'watchActive filters by riskId, treating an empty list as universal',
    () async {
      await seedPoint('org-alpha', 'specific', applicableRisks: ['high']);
      await seedPoint('org-alpha', 'other', applicableRisks: ['low']);
      await seedPoint('org-alpha', 'universal');

      final repository = SafetyMeetingPointRepository(
        firestoreService: FirestoreService(firestore: firestore),
        organizationId: 'org-alpha',
      );

      final items = await repository.watchActive(riskId: 'high').first;

      expect(items.map((i) => i.id).toSet(), {'specific', 'universal'});
    },
  );

  test('getById returns null for a missing document', () async {
    final repository = SafetyMeetingPointRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    expect(await repository.getById('missing'), isNull);
  });

  test('organizationId exposes the scope this repository was built with', () {
    final repository = SafetyMeetingPointRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    expect(repository.organizationId, 'org-alpha');
  });
}
