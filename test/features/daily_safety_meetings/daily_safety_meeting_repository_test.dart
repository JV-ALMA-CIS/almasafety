import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/features/daily_safety_meetings/data/daily_safety_meeting_repository.dart';

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<void> seedMeeting(
    String orgId,
    String id, {
    required String foremanId,
    required String siteId,
    required String date,
    String status = 'inProgress',
  }) async {
    await firestore.doc('organizations/$orgId/daily_safety_meetings/$id').set({
      'organizationId': orgId,
      'projectId': 'project-1',
      'siteId': siteId,
      'date': date,
      'foremanId': foremanId,
      'activityIds': <String>[],
      'meetingPointIds': <String>[],
      'status': status,
      'concerns': <String>[],
      'correctiveActionIds': <String>[],
      'createdAt': Timestamp.now(),
    });
  }

  test(
    'watchForForemanSiteAndDate returns only that foreman+site+date',
    () async {
      await seedMeeting(
        'org-alpha',
        'm1',
        foremanId: 'foreman-1',
        siteId: 'site-1',
        date: '2026-08-20',
      );
      await seedMeeting(
        'org-alpha',
        'm2',
        foremanId: 'foreman-2',
        siteId: 'site-1',
        date: '2026-08-20',
      );
      await seedMeeting(
        'org-alpha',
        'm3',
        foremanId: 'foreman-1',
        siteId: 'site-2',
        date: '2026-08-20',
      );
      await seedMeeting(
        'org-alpha',
        'm4',
        foremanId: 'foreman-1',
        siteId: 'site-1',
        date: '2026-08-19',
      );

      final repository = DailySafetyMeetingRepository(
        firestoreService: FirestoreService(firestore: firestore),
        organizationId: 'org-alpha',
      );

      final items = await repository
          .watchForForemanSiteAndDate(
            foremanId: 'foreman-1',
            siteId: 'site-1',
            date: '2026-08-20',
          )
          .first;

      expect(items.map((i) => i.id).toSet(), {'m1'});
    },
  );

  test('watchForForemanSiteAndDate excludes another organization', () async {
    await seedMeeting(
      'org-alpha',
      'm1',
      foremanId: 'foreman-1',
      siteId: 'site-1',
      date: '2026-08-20',
    );
    await seedMeeting(
      'org-beta',
      'm2',
      foremanId: 'foreman-1',
      siteId: 'site-1',
      date: '2026-08-20',
    );

    final repository = DailySafetyMeetingRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final items = await repository
        .watchForForemanSiteAndDate(
          foremanId: 'foreman-1',
          siteId: 'site-1',
          date: '2026-08-20',
        )
        .first;

    expect(items.map((i) => i.id).toSet(), {'m1'});
  });

  test('watchForSiteAndDate returns every meeting at that site+date, '
      'regardless of foreman', () async {
    await seedMeeting(
      'org-alpha',
      'm1',
      foremanId: 'foreman-1',
      siteId: 'site-1',
      date: '2026-08-20',
    );
    await seedMeeting(
      'org-alpha',
      'm2',
      foremanId: 'foreman-2',
      siteId: 'site-2',
      date: '2026-08-20',
    );
    await seedMeeting(
      'org-alpha',
      'm3',
      foremanId: 'foreman-1',
      siteId: 'site-1',
      date: '2026-08-19',
    );

    final repository = DailySafetyMeetingRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final items = await repository
        .watchForSiteAndDate(siteId: 'site-1', date: '2026-08-20')
        .first;

    expect(items.map((i) => i.id).toSet(), {'m1'});
  });

  test('watchForSiteAndDate excludes another organization', () async {
    await seedMeeting(
      'org-alpha',
      'm1',
      foremanId: 'foreman-1',
      siteId: 'site-1',
      date: '2026-08-20',
    );
    await seedMeeting(
      'org-beta',
      'm2',
      foremanId: 'foreman-1',
      siteId: 'site-1',
      date: '2026-08-20',
    );

    final repository = DailySafetyMeetingRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    final items = await repository
        .watchForSiteAndDate(siteId: 'site-1', date: '2026-08-20')
        .first;

    expect(items.map((i) => i.id).toSet(), {'m1'});
  });

  test(
    'watchHistoryForForeman returns only that foreman across dates',
    () async {
      await seedMeeting(
        'org-alpha',
        'm1',
        foremanId: 'foreman-1',
        siteId: 'site-1',
        date: '2026-08-18',
        status: 'completed',
      );
      await seedMeeting(
        'org-alpha',
        'm2',
        foremanId: 'foreman-1',
        siteId: 'site-1',
        date: '2026-08-19',
        status: 'completed',
      );
      await seedMeeting(
        'org-alpha',
        'm3',
        foremanId: 'foreman-2',
        siteId: 'site-1',
        date: '2026-08-19',
        status: 'completed',
      );

      final repository = DailySafetyMeetingRepository(
        firestoreService: FirestoreService(firestore: firestore),
        organizationId: 'org-alpha',
      );

      final items = await repository.watchHistoryForForeman('foreman-1').first;

      expect(items.map((i) => i.id).toList(), ['m2', 'm1']);
    },
  );

  test('getById returns null for a missing document', () async {
    final repository = DailySafetyMeetingRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    expect(await repository.getById('missing'), isNull);
  });

  test('organizationId exposes the scope this repository was built with', () {
    final repository = DailySafetyMeetingRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
    );

    expect(repository.organizationId, 'org-alpha');
  });
}
