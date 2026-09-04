import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/errors/app_exception.dart';
import 'meeting_concern_category.dart';
import 'meeting_concern_status.dart';

/// One concern raised during one [DailySafetyMeeting], stored at
/// `organizations/{organizationId}/daily_safety_meetings/{meetingId}/concerns/{id}`
/// — a subcollection of the meeting, mirroring [MeetingAttendance]'s shape
/// exactly except for the document id: a worker can only have one attendance
/// record, but a meeting can have many concerns, so this uses an auto-id
/// rather than a deterministic one.
///
/// **Concerns become part of the permanent meeting record once the meeting
/// is completed.** While the meeting is `inProgress`, its own foreman may
/// add, edit and remove concerns freely through `addMeetingConcern`/
/// `updateMeetingConcern`/`removeMeetingConcern`. Once the meeting is
/// `completed`, every one of those callables refuses — a completed meeting's
/// concerns are a closed historical record, exactly like
/// [DailySafetyMeeting]'s own `activityIds`/`meetingPointIds` become
/// unreachable after completion.
///
/// Created and edited exclusively through those callables by the meeting's
/// own foreman — see `functions/src/daily_safety_meeting_callable.ts`.
/// Read-only client-side, mirroring [MeetingAttendance].
class MeetingConcern {
  const MeetingConcern({
    required this.id,
    required this.meetingId,
    required this.organizationId,
    required this.siteId,
    required this.description,
    required this.category,
    required this.reportedBy,
    required this.status,
    this.createdAt,
  });

  final String id;
  final String meetingId;
  final String organizationId;
  final String siteId;
  final String description;
  final MeetingConcernCategory category;
  final String reportedBy;
  final MeetingConcernStatus status;
  final DateTime? createdAt;

  /// Parses a meeting concern document. Throws [DataException] on a missing
  /// or malformed document — see [MeetingAttendance.fromFirestore] for why.
  factory MeetingConcern.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    if (data == null) {
      throw const DataException('That concern could not be loaded.');
    }
    return MeetingConcern.fromMap(doc.id, data);
  }

  factory MeetingConcern.fromMap(String id, Map<String, dynamic> data) {
    final status = MeetingConcernStatus.tryFromId(data['status'] as String?);
    if (status == null) {
      throw const DataException('That concern has an unrecognised status.');
    }
    final category = MeetingConcernCategory.tryFromId(
      data['category'] as String?,
    );
    if (category == null) {
      throw const DataException('That concern has an unrecognised category.');
    }
    final meetingId = data['meetingId'] as String?;
    if (meetingId == null || meetingId.isEmpty) {
      throw const DataException('That concern has no meeting.');
    }
    final organizationId = data['organizationId'] as String?;
    if (organizationId == null || organizationId.isEmpty) {
      throw const DataException('That concern has no organization.');
    }
    final siteId = data['siteId'] as String?;
    if (siteId == null || siteId.isEmpty) {
      throw const DataException('That concern has no site.');
    }
    final description = data['description'] as String?;
    if (description == null || description.isEmpty) {
      throw const DataException('That concern has no description.');
    }
    final reportedBy = data['reportedBy'] as String?;
    if (reportedBy == null || reportedBy.isEmpty) {
      throw const DataException('That concern has no reporter.');
    }
    return MeetingConcern(
      id: id,
      meetingId: meetingId,
      organizationId: organizationId,
      siteId: siteId,
      description: description,
      category: category,
      reportedBy: reportedBy,
      status: status,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}
