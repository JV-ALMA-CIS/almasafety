import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/features/corrective_actions/data/corrective_action_repository.dart';

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<void> seedAction(
    String orgId,
    String id, {
    String? meetingId,
    String? concernId,
    String? hazardId,
    String siteId = 'site-1',
    String status = 'open',
  }) async {
    await firestore.doc('organizations/$orgId/corrective_actions/$id').set({
      'organizationId': orgId,
      'projectId': 'project-1',
      'siteId': siteId,
      'meetingId': meetingId,
      'concernId': concernId,
      'hazardId': hazardId,
      'title': 'Action $id',
      'description': 'Description $id',
      'assignedTo': 'worker-1',
      'assignedBy': 'foreman-1',
      'dueDate': Timestamp.fromDate(DateTime(2026, 9, 1)),
      'status': status,
      'evidenceRequired': false,
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
  }

  test('watchForMeeting returns only actions for that meeting', () async {
    await seedAction('org-alpha', 'ca1', meetingId: 'm1');
    await seedAction('org-alpha', 'ca2', meetingId: 'm1');
    await seedAction('org-alpha', 'ca3', meetingId: 'm2');

    final repository = CorrectiveActionRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final actions = await repository.watchForMeeting('m1').first;

    expect(actions.map((a) => a.id).toSet(), {'ca1', 'ca2'});
  });

  test('watchForConcern returns only actions raised from that concern',
      () async {
    await seedAction('org-alpha', 'ca1', meetingId: 'm1', concernId: 'c1');
    await seedAction('org-alpha', 'ca2', meetingId: 'm1', concernId: 'c2');
    await seedAction('org-alpha', 'ca3', meetingId: 'm1');

    final repository = CorrectiveActionRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final actions = await repository.watchForConcern('c1').first;

    expect(actions.map((a) => a.id).toList(), ['ca1']);
  });

  test('watchForHazard returns only the action raised from that hazard',
    () async {
      await seedAction('org-alpha', 'ca1', hazardId: 'hazard-1');
      await seedAction('org-alpha', 'ca2', meetingId: 'm1');

      final repository = CorrectiveActionRepository(
        firestoreService: FirestoreService(firestore: firestore),
        organizationId: 'org-alpha',
      );

      final actions = await repository.watchForHazard('hazard-1').first;

      expect(actions.map((a) => a.id).toList(), ['ca1']);
      expect(actions.single.hazardId, 'hazard-1');
      expect(actions.single.meetingId, isNull);
    });

  test('watchForOrganization returns every action across meetings/sites',
      () async {
    await seedAction(
      'org-alpha',
      'ca1',
      meetingId: 'm1',
      siteId: 'site-1',
    );
    await seedAction(
      'org-alpha',
      'ca2',
      meetingId: 'm2',
      siteId: 'site-2',
    );

    final repository = CorrectiveActionRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final actions = await repository.watchForOrganization().first;

    expect(actions.map((a) => a.id).toSet(), {'ca1', 'ca2'});
  });

  test("watchForOrganization excludes another organization's actions",
      () async {
    await seedAction('org-alpha', 'ca1', meetingId: 'm1');
    await seedAction('org-beta', 'ca1', meetingId: 'm1');

    final repository = CorrectiveActionRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final actions = await repository.watchForOrganization().first;

    expect(actions, hasLength(1));
    expect(actions.single.organizationId, 'org-alpha');
  });

  test('getById returns null for a missing document', () async {
    final repository = CorrectiveActionRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    expect(await repository.getById('missing'), isNull);
  });

  test('organizationId exposes the scope this repository was built with',
      () {
    final repository = CorrectiveActionRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    expect(repository.organizationId, 'org-alpha');
  });
}
