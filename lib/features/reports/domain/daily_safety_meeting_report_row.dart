import '../../daily_safety_meetings/domain/daily_safety_meeting_status.dart';

/// One Daily Safety Meeting report row — a read-only aggregation of a
/// [DailySafetyMeeting] with its attendance, concerns and corrective action
/// counts, assembled by `ReportsRepository`.
///
/// **A view model, not a Firestore-backed domain type.** Nothing here is
/// parsed from a single document or written anywhere; it is built entirely
/// from data already readable through existing, unmodified repositories
/// (`DailySafetyMeetingRepository`, `MeetingAttendanceRepository`,
/// `MeetingConcernRepository`, `CorrectiveActionRepository`), matching this
/// stage's "reports are read-only" requirement — there is no new Firestore
/// collection, no new callable, and no new write path anywhere in this
/// feature.
class DailySafetyMeetingReportRow {
  const DailySafetyMeetingReportRow({
    required this.meetingId,
    required this.projectId,
    required this.projectName,
    required this.siteId,
    required this.siteName,
    required this.date,
    required this.status,
    required this.foremanId,
    required this.activityCount,
    required this.meetingPointCount,
    required this.presentCount,
    required this.absentCount,
    required this.concernCount,
    required this.correctiveActionCount,
  });

  final String meetingId;
  final String projectId;
  final String projectName;
  final String siteId;
  final String siteName;

  /// The meeting's own `yyyy-MM-dd` date string — see
  /// `DailySafetyMeeting.date`'s doc comment for why this is a string, not a
  /// [DateTime].
  final String date;
  final DailySafetyMeetingStatus status;
  final String foremanId;
  final int activityCount;
  final int meetingPointCount;
  final int presentCount;
  final int absentCount;
  final int concernCount;
  final int correctiveActionCount;
}
