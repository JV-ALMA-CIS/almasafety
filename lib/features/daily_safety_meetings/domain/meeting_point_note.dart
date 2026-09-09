import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/errors/app_exception.dart';

/// One safety meeting point's discussion note for one [DailySafetyMeeting],
/// stored at
/// `organizations/{organizationId}/daily_safety_meetings/{meetingId}/point_notes/{meetingPointId}`
/// — a subcollection of the meeting, keyed by the meeting point's own id so
/// a note is idempotent to set/overwrite, mirroring
/// [MeetingAttendance]'s "worker uid as document id" shape.
///
/// **This is deliberately NOT a [MeetingConcern].** A note is plain free
/// text describing what was actually explained, discussed, instructed or
/// decided about a covered meeting point — e.g. "reminded workers to
/// maintain three points of contact on ladders; team confirmed
/// understanding" — never an issue with a category or status. It exists to
/// close the specific evidentiary gap where checking a meeting point's
/// checkbox alone proves nothing about whether it was genuinely discussed.
/// Optional: a meeting completes with or without notes on any given point.
///
/// Created and edited exclusively through the `setMeetingPointNote`/
/// `removeMeetingPointNote` callables by the meeting's own foreman, only
/// while the meeting is `inProgress` — see
/// `functions/src/daily_safety_meeting_callable.ts`. Read-only client-side,
/// mirroring [MeetingConcern].
class MeetingPointNote {
  const MeetingPointNote({
    required this.meetingId,
    required this.organizationId,
    required this.siteId,
    required this.meetingPointId,
    required this.note,
    this.recordedBy,
    this.createdAt,
    this.updatedAt,
  });

  final String meetingId;
  final String organizationId;
  final String siteId;
  final String meetingPointId;
  final String note;
  final String? recordedBy;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// Parses a meeting point note document. Throws [DataException] on a
  /// missing or malformed document — see [MeetingAttendance.fromFirestore]
  /// for why.
  factory MeetingPointNote.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    if (data == null) {
      throw const DataException('That meeting point note could not be loaded.');
    }
    return MeetingPointNote.fromMap(doc.id, data);
  }

  factory MeetingPointNote.fromMap(String id, Map<String, dynamic> data) {
    final meetingId = data['meetingId'] as String?;
    if (meetingId == null || meetingId.isEmpty) {
      throw const DataException('That meeting point note has no meeting.');
    }
    final organizationId = data['organizationId'] as String?;
    if (organizationId == null || organizationId.isEmpty) {
      throw const DataException(
        'That meeting point note has no organization.',
      );
    }
    final siteId = data['siteId'] as String?;
    if (siteId == null || siteId.isEmpty) {
      throw const DataException('That meeting point note has no site.');
    }
    final meetingPointId = data['meetingPointId'] as String? ?? id;
    if (meetingPointId.isEmpty) {
      throw const DataException(
        'That meeting point note has no meeting point.',
      );
    }
    final note = data['note'] as String?;
    if (note == null || note.isEmpty) {
      throw const DataException('That meeting point note has no text.');
    }
    return MeetingPointNote(
      meetingId: meetingId,
      organizationId: organizationId,
      siteId: siteId,
      meetingPointId: meetingPointId,
      note: note,
      recordedBy: data['recordedBy'] as String?,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
    );
  }
}
