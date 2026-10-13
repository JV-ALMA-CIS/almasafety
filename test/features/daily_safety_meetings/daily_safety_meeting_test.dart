import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/features/daily_safety_meetings/domain/daily_safety_meeting.dart';
import 'package:jva_safety/features/daily_safety_meetings/domain/daily_safety_meeting_status.dart';

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<DocumentSnapshot<Map<String, dynamic>>> seed(
    Map<String, dynamic> data,
  ) async {
    final ref = firestore.doc(
      'organizations/org-alpha/daily_safety_meetings/m1',
    );
    await ref.set(data);
    return ref.get();
  }

  test('fromFirestore parses every field', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
      'date': '2026-08-20',
      'startTime': Timestamp.now(),
      'endTime': Timestamp.now(),
      'foremanId': 'foreman-1',
      'activityIds': ['activity-1', 'activity-2'],
      'meetingPointIds': ['point-1'],
      'status': 'completed',
      'concerns': ['Loose scaffolding on level 3'],
      'correctiveActionIds': <String>[],
      'createdAt': Timestamp.now(),
      'completedAt': Timestamp.now(),
    });

    final meeting = DailySafetyMeeting.fromFirestore(doc);

    expect(meeting.id, 'm1');
    expect(meeting.organizationId, 'org-alpha');
    expect(meeting.projectId, 'project-1');
    expect(meeting.siteId, 'site-1');
    expect(meeting.date, '2026-08-20');
    expect(meeting.foremanId, 'foreman-1');
    expect(meeting.activityIds, ['activity-1', 'activity-2']);
    expect(meeting.meetingPointIds, ['point-1']);
    expect(meeting.status, DailySafetyMeetingStatus.completed);
    expect(meeting.isCompleted, isTrue);
    expect(meeting.concerns, ['Loose scaffolding on level 3']);
  });

  test(
    'defaults list fields to empty and status to inProgress fields',
    () async {
      final doc = await seed({
        'organizationId': 'org-alpha',
        'projectId': 'project-1',
        'siteId': 'site-1',
        'date': '2026-08-20',
        'foremanId': 'foreman-1',
        'status': 'inProgress',
      });

      final meeting = DailySafetyMeeting.fromFirestore(doc);

      expect(meeting.activityIds, isEmpty);
      expect(meeting.meetingPointIds, isEmpty);
      expect(meeting.concerns, isEmpty);
      expect(meeting.correctiveActionIds, isEmpty);
      expect(meeting.isCompleted, isFalse);
    },
  );

  test('throws when organizationId is missing', () async {
    final doc = await seed({
      'projectId': 'project-1',
      'siteId': 'site-1',
      'date': '2026-08-20',
      'foremanId': 'foreman-1',
      'status': 'inProgress',
    });

    expect(
      () => DailySafetyMeeting.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('throws when siteId is missing', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'date': '2026-08-20',
      'foremanId': 'foreman-1',
      'status': 'inProgress',
    });

    expect(
      () => DailySafetyMeeting.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('throws when foremanId is missing', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
      'date': '2026-08-20',
      'status': 'inProgress',
    });

    expect(
      () => DailySafetyMeeting.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('throws on an unrecognised status', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'projectId': 'project-1',
      'siteId': 'site-1',
      'date': '2026-08-20',
      'foremanId': 'foreman-1',
      'status': 'archived',
    });

    expect(
      () => DailySafetyMeeting.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('every DailySafetyMeetingStatus round-trips through its stored id', () {
    for (final status in DailySafetyMeetingStatus.values) {
      expect(DailySafetyMeetingStatus.tryFromId(status.id), status);
    }
    expect(DailySafetyMeetingStatus.tryFromId('unknown'), isNull);
    expect(DailySafetyMeetingStatus.tryFromId(null), isNull);
  });
}
