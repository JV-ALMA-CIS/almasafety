import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/errors/app_exception.dart';
import '../../pre_start_checks/domain/pre_start_outcome.dart';
import 'daily_safety_meeting_status.dart';

/// A record of one toolbox-talk-style Daily Safety Meeting, stored at
/// `organizations/{organizationId}/daily_safety_meetings/{id}` — a flat
/// sibling of `safety_meeting_points` and `activities`, matching
/// [SafetyMeetingPoint]'s doc comment's shape.
///
/// **This platform records the meeting; it does not conduct it.** The
/// physical toolbox talk happens off-platform. This document is what a
/// foreman fills in before and after it: which of the site's activities the
/// meeting covers, which recommended [SafetyMeetingPoint]s were accepted,
/// and — once the talk is done — any concerns raised and that it happened.
/// There is deliberately no audio, transcript or language field anywhere on
/// this model: [concerns] is a caller-supplied list of plain strings, stored
/// and shown verbatim.
///
/// Created and edited exclusively through the `createDailySafetyMeeting`/
/// `updateDailySafetyMeeting`/`completeDailySafetyMeeting` callables by the
/// meeting's own foreman — see
/// `functions/src/daily_safety_meeting_callable.ts`. Read-only client-side,
/// mirroring [SafetyMeetingPoint].
class DailySafetyMeeting {
  const DailySafetyMeeting({
    required this.id,
    required this.organizationId,
    required this.projectId,
    required this.siteId,
    required this.date,
    required this.foremanId,
    required this.status,
    this.startTime,
    this.endTime,
    this.activityIds = const [],
    this.meetingPointIds = const [],
    this.concerns = const [],
    this.correctiveActionIds = const [],
    this.createdAt,
    this.completedAt,
    this.crewOutcome,
    this.crewOutcomeNote,
    this.ahaIds = const [],
    this.ahasCovered = const [],
  });

  final String id;
  final String organizationId;
  final String projectId;
  final String siteId;

  /// The calendar date this meeting belongs to, as a server-assigned
  /// `yyyy-MM-dd` string rather than a full timestamp — a meeting belongs to
  /// one day, and this is what "today's meeting" queries filter on.
  final String date;
  final DateTime? startTime;
  final DateTime? endTime;
  final String foremanId;
  final List<String> activityIds;
  final List<String> meetingPointIds;
  final DailySafetyMeetingStatus status;
  final List<String> concerns;

  /// Ids of corrective actions raised from this meeting. Always empty at
  /// this stage — Corrective Actions is a later feature — but the field is
  /// modeled now so that feature does not need a migration to attach here.
  final List<String> correctiveActionIds;
  final DateTime? createdAt;
  final DateTime? completedAt;

  /// The Foreman's GO / GO corrected / STOP result for the crew, recorded
  /// when the meeting was completed. Null while in progress, and for a
  /// meeting completed before crew results existed.
  final PreStartOutcome? crewOutcome;

  /// The Foreman's note for a GO corrected / STOP [crewOutcome].
  final String? crewOutcomeNote;

  /// The accepted risk assessments (AHAs) the Foreman covered with the
  /// crew — the Safety Plan: "cover the activity hazard analysis before
  /// work begins".
  final List<String> ahaIds;

  /// [ahaIds] as recorded at the time (name and revision), so a completed
  /// meeting still says what was covered after the AHA is revised.
  final List<CoveredAha> ahasCovered;

  bool get isCompleted => status == DailySafetyMeetingStatus.completed;

  /// Parses a daily safety meeting document. Throws [DataException] on a
  /// missing or malformed document — see [SafetyMeetingPoint.fromFirestore]
  /// for why.
  factory DailySafetyMeeting.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    if (data == null) {
      throw const DataException(
        'That daily safety meeting could not be loaded.',
      );
    }
    return DailySafetyMeeting.fromMap(doc.id, data);
  }

  factory DailySafetyMeeting.fromMap(String id, Map<String, dynamic> data) {
    final status = DailySafetyMeetingStatus.tryFromId(
      data['status'] as String?,
    );
    if (status == null) {
      throw const DataException(
        'That daily safety meeting has an unrecognised status.',
      );
    }
    final organizationId = data['organizationId'] as String?;
    if (organizationId == null || organizationId.isEmpty) {
      throw const DataException(
        'That daily safety meeting has no organization.',
      );
    }
    final projectId = data['projectId'] as String?;
    if (projectId == null || projectId.isEmpty) {
      throw const DataException('That daily safety meeting has no project.');
    }
    final siteId = data['siteId'] as String?;
    if (siteId == null || siteId.isEmpty) {
      throw const DataException('That daily safety meeting has no site.');
    }
    final foremanId = data['foremanId'] as String?;
    if (foremanId == null || foremanId.isEmpty) {
      throw const DataException('That daily safety meeting has no foreman.');
    }
    return DailySafetyMeeting(
      id: id,
      organizationId: organizationId,
      projectId: projectId,
      siteId: siteId,
      date: data['date'] as String? ?? '',
      startTime: (data['startTime'] as Timestamp?)?.toDate(),
      endTime: (data['endTime'] as Timestamp?)?.toDate(),
      foremanId: foremanId,
      activityIds:
          (data['activityIds'] as List<dynamic>?)?.cast<String>().toList() ??
          const [],
      meetingPointIds:
          (data['meetingPointIds'] as List<dynamic>?)
              ?.cast<String>()
              .toList() ??
          const [],
      status: status,
      concerns:
          (data['concerns'] as List<dynamic>?)?.cast<String>().toList() ??
          const [],
      correctiveActionIds:
          (data['correctiveActionIds'] as List<dynamic>?)
              ?.cast<String>()
              .toList() ??
          const [],
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      completedAt: (data['completedAt'] as Timestamp?)?.toDate(),
      crewOutcome: PreStartOutcome.tryFromId(data['crewOutcome']),
      crewOutcomeNote: data['crewOutcomeNote'] as String?,
      ahaIds:
          (data['ahaIds'] as List<dynamic>?)?.whereType<String>().toList() ??
          const [],
      ahasCovered: [
        for (final raw in (data['ahasCovered'] as List<dynamic>?) ?? const [])
          if (raw is Map && raw['id'] is String)
            CoveredAha(
              id: raw['id'] as String,
              featureOfWork: raw['featureOfWork'] as String? ?? '',
              revision: (raw['revision'] as num?)?.toInt() ?? 1,
            ),
      ],
    );
  }
}

/// A risk assessment (AHA) covered at a meeting, as recorded at the time.
class CoveredAha {
  const CoveredAha({
    required this.id,
    required this.featureOfWork,
    required this.revision,
  });

  final String id;
  final String featureOfWork;
  final int revision;
}
