import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/errors/app_exception.dart';

/// A point the Foreman typed themself for one [DailySafetyMeeting], stored
/// at
/// `organizations/{organizationId}/daily_safety_meetings/{meetingId}/foreman_points/{id}`.
///
/// For what was discussed that the Safety Meeting Point library does not
/// cover: a short [title], an optional [note] on what was said, and an
/// optional [activityId] (one of the meeting's own activities). It belongs
/// to this meeting only — it never becomes a library point — and counts
/// towards completing the meeting the same as a library point.
///
/// Written only through the `saveMeetingForemanPoint`/
/// `removeMeetingForemanPoint` callables by the meeting's own foreman;
/// adding is allowed after completion, editing and removing are not.
/// Read-only client-side, mirroring [MeetingPointNote].
class MeetingForemanPoint {
  const MeetingForemanPoint({
    required this.id,
    required this.meetingId,
    required this.organizationId,
    required this.siteId,
    required this.title,
    this.note,
    this.activityId,
    this.recordedBy,
    this.createdAt,
  });

  /// Longest title, matching the server's limit.
  static const titleMaxLength = 120;

  /// Longest note, matching the server's limit and point notes.
  static const noteMaxLength = 500;

  final String id;
  final String meetingId;
  final String organizationId;
  final String siteId;
  final String title;
  final String? note;
  final String? activityId;
  final String? recordedBy;
  final DateTime? createdAt;

  /// Parses a Foreman's point document. Throws [DataException] on a missing
  /// or malformed document — see [MeetingAttendance.fromFirestore] for why.
  factory MeetingForemanPoint.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    if (data == null) {
      throw const DataException('That meeting point could not be loaded.');
    }
    return MeetingForemanPoint.fromMap(doc.id, data);
  }

  factory MeetingForemanPoint.fromMap(String id, Map<String, dynamic> data) {
    final meetingId = data['meetingId'] as String?;
    final organizationId = data['organizationId'] as String?;
    final siteId = data['siteId'] as String?;
    final title = data['title'] as String?;
    if (meetingId == null ||
        meetingId.isEmpty ||
        organizationId == null ||
        organizationId.isEmpty ||
        siteId == null ||
        siteId.isEmpty ||
        title == null ||
        title.isEmpty) {
      throw const DataException('That meeting point is incomplete.');
    }
    final note = data['note'] as String?;
    final activityId = data['activityId'] as String?;
    return MeetingForemanPoint(
      id: id,
      meetingId: meetingId,
      organizationId: organizationId,
      siteId: siteId,
      title: title,
      note: note == null || note.isEmpty ? null : note,
      activityId: activityId == null || activityId.isEmpty ? null : activityId,
      recordedBy: data['recordedBy'] as String?,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
    );
  }

  /// The point as the app sends it to `saveMeetingForemanPoint` — also how a
  /// point saved with no signal is read back from the phone's outbox.
  factory MeetingForemanPoint.fromCallableData(Map<String, Object?> data) =>
      MeetingForemanPoint(
        id: data['pointId']! as String,
        meetingId: data['meetingId']! as String,
        organizationId: data['organizationId']! as String,
        siteId: '',
        title: data['title']! as String,
        note: data['note'] as String?,
        activityId: data['activityId'] as String?,
      );
}
