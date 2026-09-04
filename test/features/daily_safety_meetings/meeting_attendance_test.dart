import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/features/daily_safety_meetings/domain/meeting_attendance.dart';
import 'package:jva_safety/features/daily_safety_meetings/domain/meeting_attendance_status.dart';

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<DocumentSnapshot<Map<String, dynamic>>> seed(
    Map<String, dynamic> data,
  ) async {
    final ref = firestore.doc(
      'organizations/org-alpha/daily_safety_meetings/m1/attendance/worker-1',
    );
    await ref.set(data);
    return ref.get();
  }

  test('fromFirestore parses every field', () async {
    final doc = await seed({
      'meetingId': 'm1',
      'organizationId': 'org-alpha',
      'siteId': 'site-1',
      'workerId': 'worker-1',
      'status': 'present',
      'recordedAt': Timestamp.now(),
      'recordedBy': 'foreman-1',
    });

    final attendance = MeetingAttendance.fromFirestore(doc);

    expect(attendance.meetingId, 'm1');
    expect(attendance.organizationId, 'org-alpha');
    expect(attendance.siteId, 'site-1');
    expect(attendance.workerId, 'worker-1');
    expect(attendance.status, MeetingAttendanceStatus.present);
    expect(attendance.recordedBy, 'foreman-1');
  });

  test('falls back to the document id when workerId is missing', () async {
    final doc = await seed({
      'meetingId': 'm1',
      'organizationId': 'org-alpha',
      'siteId': 'site-1',
      'status': 'absent',
    });

    final attendance = MeetingAttendance.fromFirestore(doc);

    expect(attendance.workerId, 'worker-1');
    expect(attendance.status, MeetingAttendanceStatus.absent);
  });

  test('throws when organizationId is missing', () async {
    final doc = await seed({
      'meetingId': 'm1',
      'siteId': 'site-1',
      'workerId': 'worker-1',
      'status': 'present',
    });

    expect(
      () => MeetingAttendance.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('throws when siteId is missing', () async {
    final doc = await seed({
      'meetingId': 'm1',
      'organizationId': 'org-alpha',
      'workerId': 'worker-1',
      'status': 'present',
    });

    expect(
      () => MeetingAttendance.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('throws when meetingId is missing', () async {
    final doc = await seed({
      'organizationId': 'org-alpha',
      'siteId': 'site-1',
      'workerId': 'worker-1',
      'status': 'present',
    });

    expect(
      () => MeetingAttendance.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('throws on an unrecognised status', () async {
    final doc = await seed({
      'meetingId': 'm1',
      'organizationId': 'org-alpha',
      'siteId': 'site-1',
      'workerId': 'worker-1',
      'status': 'late',
    });

    expect(
      () => MeetingAttendance.fromFirestore(doc),
      throwsA(isA<DataException>()),
    );
  });

  test('every MeetingAttendanceStatus round-trips through its stored id', () {
    for (final status in MeetingAttendanceStatus.values) {
      expect(MeetingAttendanceStatus.tryFromId(status.id), status);
    }
    expect(MeetingAttendanceStatus.tryFromId('unknown'), isNull);
    expect(MeetingAttendanceStatus.tryFromId(null), isNull);
  });
}
