import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/features/daily_safety_meetings/data/meeting_concern_repository.dart';

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<void> seedConcern(
    String orgId,
    String meetingId,
    String concernId, {
    String siteId = 'site-1',
    String category = 'safety',
    String status = 'open',
  }) async {
    await firestore
        .doc(
          'organizations/$orgId/daily_safety_meetings/$meetingId/concerns/'
          '$concernId',
        )
        .set({
          'meetingId': meetingId,
          'organizationId': orgId,
          'siteId': siteId,
          'description': 'Concern $concernId',
          'category': category,
          'reportedBy': 'foreman-1',
          'status': status,
          'createdAt': Timestamp.now(),
        });
  }

  test('watchAll returns only concerns for this meeting', () async {
    await seedConcern('org-alpha', 'm1', 'c1');
    await seedConcern('org-alpha', 'm1', 'c2');
    await seedConcern('org-alpha', 'm2', 'c3');

    final repository = MeetingConcernRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
      meetingId: 'm1',
    );

    final concerns = await repository.watchAll().first;

    expect(concerns.map((c) => c.id).toSet(), {'c1', 'c2'});
  });

  test("watchAll excludes another organization's concerns", () async {
    await seedConcern('org-alpha', 'm1', 'c1');
    await seedConcern('org-beta', 'm1', 'c1');

    final repository = MeetingConcernRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
      meetingId: 'm1',
    );

    final concerns = await repository.watchAll().first;

    expect(concerns, hasLength(1));
    expect(concerns.single.organizationId, 'org-alpha');
  });

  test(
    'watchAll returns an empty list for a meeting with no concerns',
    () async {
      final repository = MeetingConcernRepository(
        firestoreService: FirestoreService(firestore: firestore),
        organizationId: 'org-alpha',
        meetingId: 'm1',
      );

      expect(await repository.watchAll().first, isEmpty);
    },
  );

  test('organizationId and meetingId expose the scope this repository was '
      'built with', () {
    final repository = MeetingConcernRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
      meetingId: 'm1',
    );

    expect(repository.organizationId, 'org-alpha');
    expect(repository.meetingId, 'm1');
  });
}
