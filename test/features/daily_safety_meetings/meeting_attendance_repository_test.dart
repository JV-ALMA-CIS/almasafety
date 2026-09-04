import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/services/firestore_service.dart';
import 'package:jva_safety/features/daily_safety_meetings/data/meeting_attendance_repository.dart';

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  Future<void> seedAttendance(
    String orgId,
    String meetingId,
    String workerId, {
    required String status,
    String siteId = 'site-1',
  }) async {
    await firestore
        .doc(
          'organizations/$orgId/daily_safety_meetings/$meetingId/attendance/'
          '$workerId',
        )
        .set({
      'meetingId': meetingId,
      'organizationId': orgId,
      'siteId': siteId,
      'workerId': workerId,
      'status': status,
      'recordedAt': Timestamp.now(),
      'recordedBy': 'foreman-1',
    });
  }

  test('watchAll returns only records for this meeting', () async {
    await seedAttendance('org-alpha', 'm1', 'worker-1', status: 'present');
    await seedAttendance('org-alpha', 'm1', 'worker-2', status: 'absent');
    await seedAttendance('org-alpha', 'm2', 'worker-3', status: 'present');

    final repository = MeetingAttendanceRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
      meetingId: 'm1',
    );

    final records = await repository.watchAll().first;

    expect(records.map((r) => r.workerId).toSet(), {'worker-1', 'worker-2'});
  });

  test('watchAll excludes another organization\'s attendance', () async {
    await seedAttendance('org-alpha', 'm1', 'worker-1', status: 'present');
    await seedAttendance('org-beta', 'm1', 'worker-1', status: 'absent');

    final repository = MeetingAttendanceRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
      meetingId: 'm1',
    );

    final records = await repository.watchAll().first;

    expect(records, hasLength(1));
    expect(records.single.organizationId, 'org-alpha');
  });

  test('getByWorker returns null for a worker with no record', () async {
    final repository = MeetingAttendanceRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
      meetingId: 'm1',
    );

    expect(await repository.getByWorker('missing'), isNull);
  });

  test('getByWorker returns the recorded status', () async {
    await seedAttendance('org-alpha', 'm1', 'worker-1', status: 'present');

    final repository = MeetingAttendanceRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
      meetingId: 'm1',
    );

    final record = await repository.getByWorker('worker-1');

    expect(record, isNotNull);
    expect(record!.status.id, 'present');
  });

  test('organizationId and meetingId expose the scope this repository was '
      'built with', () {
    final repository = MeetingAttendanceRepository(
      firestoreService: FirestoreService(firestore: firestore),
      organizationId: 'org-alpha',
      meetingId: 'm1',
    );

    expect(repository.organizationId, 'org-alpha');
    expect(repository.meetingId, 'm1');
  });
}
