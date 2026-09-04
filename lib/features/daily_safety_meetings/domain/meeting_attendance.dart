import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/errors/app_exception.dart';
import 'meeting_attendance_status.dart';

/// One worker's attendance record for one [DailySafetyMeeting], stored at
/// `organizations/{organizationId}/daily_safety_meetings/{meetingId}/attendance/{workerId}`
/// — a subcollection of the meeting, keyed by the worker's own uid so a
/// record is idempotent to create and trivial to look up or update.
/// Mirrors [ActivityAssignment]'s "uid as document id" idempotency pattern.
///
/// **Attendance is separate from Safety Learning completion.** This model
/// records only whether a worker was present for the physical toolbox talk
/// the meeting represents; it has no bearing on and does not modify any
/// `WorkerLearningRecord`.
///
/// Created and edited exclusively through the `recordMeetingAttendance`
/// callable by the meeting's own foreman — see
/// `functions/src/daily_safety_meeting_callable.ts`. Read-only client-side,
/// mirroring [DailySafetyMeeting].
class MeetingAttendance {
  const MeetingAttendance({
    required this.meetingId,
    required this.organizationId,
    required this.siteId,
    required this.workerId,
    required this.status,
    this.recordedAt,
    this.recordedBy,
  });

  final String meetingId;
  final String organizationId;
  final String siteId;
  final String workerId;
  final MeetingAttendanceStatus status;
  final DateTime? recordedAt;
  final String? recordedBy;

  /// Parses an attendance document. Throws [DataException] on a missing or
  /// malformed document — see [DailySafetyMeeting.fromFirestore] for why.
  factory MeetingAttendance.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    if (data == null) {
      throw const DataException('That attendance record could not be loaded.');
    }
    return MeetingAttendance.fromMap(doc.id, data);
  }

  factory MeetingAttendance.fromMap(String id, Map<String, dynamic> data) {
    final status = MeetingAttendanceStatus.tryFromId(
      data['status'] as String?,
    );
    if (status == null) {
      throw const DataException(
        'That attendance record has an unrecognised status.',
      );
    }
    final meetingId = data['meetingId'] as String?;
    if (meetingId == null || meetingId.isEmpty) {
      throw const DataException('That attendance record has no meeting.');
    }
    final organizationId = data['organizationId'] as String?;
    if (organizationId == null || organizationId.isEmpty) {
      throw const DataException(
        'That attendance record has no organization.',
      );
    }
    final siteId = data['siteId'] as String?;
    if (siteId == null || siteId.isEmpty) {
      throw const DataException('That attendance record has no site.');
    }
    final workerId = data['workerId'] as String? ?? id;
    if (workerId.isEmpty) {
      throw const DataException('That attendance record has no worker.');
    }
    return MeetingAttendance(
      meetingId: meetingId,
      organizationId: organizationId,
      siteId: siteId,
      workerId: workerId,
      status: status,
      recordedAt: (data['recordedAt'] as Timestamp?)?.toDate(),
      recordedBy: data['recordedBy'] as String?,
    );
  }
}
