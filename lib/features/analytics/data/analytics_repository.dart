import '../../../core/services/firestore_service.dart';
import '../../authentication/data/account_approval_service.dart';
import '../../corrective_actions/domain/corrective_action_status.dart';
import '../../daily_safety_meetings/data/meeting_attendance_repository.dart';
import '../../daily_safety_meetings/data/meeting_concern_repository.dart';
import '../../daily_safety_meetings/domain/daily_safety_meeting_status.dart';
import '../../daily_safety_meetings/domain/meeting_attendance_status.dart';
import '../../daily_safety_meetings/domain/meeting_concern_category.dart';
import '../../daily_safety_meetings/domain/meeting_concern_status.dart';
import '../../reports/data/reports_repository.dart';
import '../../reports/domain/safety_learning_report_row.dart';
import '../../safety_alerts/domain/safety_alert_category.dart';
import '../../safety_alerts/domain/safety_alert_severity.dart';
import '../../safety_alerts/domain/safety_alert_status.dart';
import '../domain/analytics_dashboard.dart';
import '../domain/attendance_metrics.dart';
import '../domain/concern_metrics.dart';
import '../domain/corrective_action_metrics.dart';
import '../domain/safety_alert_metrics.dart';
import '../domain/safety_learning_metrics.dart';
import '../domain/safety_meeting_metrics.dart';

/// Computes the Analytics dashboard: six metric groups, all derived by
/// composing [ReportsRepository] (itself a thin composition over existing,
/// unmodified repositories/services) plus the same per-meeting
/// attendance/concern fan-out [ReportsRepository.buildDailySafetyMeetingReport]
/// already performs.
///
/// **Read-only, by construction — no new Firestore collection.** This class
/// holds no write method of any kind. Every metric is arithmetic
/// (counting, summing, dividing) applied to data already readable through
/// existing repositories: `DailySafetyMeetingRepository`,
/// `MeetingAttendanceRepository`, `MeetingConcernRepository` (attendance and
/// concerns are fetched per-meeting rather than duplicated into a new
/// collection — see [build]'s doc comment), and every report row
/// `ReportsRepository` already assembles for Safety Alerts, Corrective
/// Actions and Safety Learning. Organization isolation is inherited from
/// those repositories' own `firestore.rules` grants, exactly like
/// [ReportsRepository] — there is no method here that could read a second
/// organization's data, by any argument.
///
/// Scoped to one organization at a time by construction, matching
/// [ReportsRepository].
class AnalyticsRepository {
  AnalyticsRepository({
    required this._firestoreService,
    required this._organizationId,
    AccountApprovalService? accountApprovalService,
  }) : _reportsRepository = ReportsRepository(
         firestoreService: _firestoreService,
         organizationId: _organizationId,
         accountApprovalService: accountApprovalService,
       );

  final FirestoreService _firestoreService;
  final String _organizationId;
  final ReportsRepository _reportsRepository;

  /// The organization this repository is scoped to.
  String get organizationId => _organizationId;

  /// Builds the full dashboard for the given filters. [projectId]/[siteId]/
  /// [from]/[to] apply to Safety Meeting, Attendance, Concern, Safety Alert
  /// and Corrective Action metrics exactly like [ReportsRepository]'s own
  /// filters — [projectId] narrows meetings only (alerts/actions have no
  /// project field of their own, matching [ReportsRepository.buildSafetyAlertsReport]/
  /// [ReportsRepository.buildCorrectiveActionsReport]'s own signatures).
  /// Safety Learning has no date/project/site dimension (a worker's
  /// required-learning set is organization-wide — see
  /// [SafetyLearningReportRow]'s doc comment), so it ignores every filter
  /// here, matching [ReportsRepository.buildSafetyLearningReport]'s own
  /// signature.
  ///
  /// [includeSafetyLearning] (default `true`, matching every existing
  /// caller's behavior — [AnalyticsScreen] always wants it) gates
  /// [ReportsRepository.buildSafetyLearningReport] specifically: that method
  /// runs one `collectionGroup('assignments')` query PER ACTIVE WORKER in
  /// the organization, concurrently, via `Future.wait`. [AnalyticsScreen]
  /// only ever calls [build] from an explicit "Refresh" tap, so that fan-out
  /// happens once per deliberate user action. A dashboard that calls [build]
  /// automatically on every visit must NOT trigger that same fan-out
  /// automatically — passing `false` here skips it and returns a
  /// zero-valued [SafetyLearningMetrics] instead; callers that still want a
  /// Learning Compliance number on such a screen should source it from
  /// [SafetyComplianceRepository] instead (already used safely by
  /// [ForemanDashboardScreen], since it queries per SITE, not per worker
  /// across the whole organization).
  Future<AnalyticsDashboard> build({
    String? projectId,
    String? siteId,
    DateTime? from,
    DateTime? to,
    bool includeSafetyLearning = true,
  }) async {
    final meetingRows = await _reportsRepository.buildDailySafetyMeetingReport(
      projectId: projectId,
      siteId: siteId,
      from: from,
      to: to,
    );
    final alertRows = await _reportsRepository.buildSafetyAlertsReport(
      siteId: siteId,
      from: from,
      to: to,
    );
    final actionRows = await _reportsRepository.buildCorrectiveActionsReport(
      siteId: siteId,
      from: from,
      to: to,
    );
    final learningRows = includeSafetyLearning
        ? await _reportsRepository.buildSafetyLearningReport()
        : const <SafetyLearningReportRow>[];

    final attendanceByMeeting = await Future.wait(
      meetingRows.map((row) async {
        final repository = MeetingAttendanceRepository(
          firestoreService: _firestoreService,
          organizationId: _organizationId,
          meetingId: row.meetingId,
        );
        return repository.watchAll().first;
      }),
    );
    final concernsByMeeting = await Future.wait(
      meetingRows.map((row) async {
        final repository = MeetingConcernRepository(
          firestoreService: _firestoreService,
          organizationId: _organizationId,
          meetingId: row.meetingId,
        );
        return repository.watchAll().first;
      }),
    );

    final bySite = <String, int>{};
    final byDate = <String, int>{};
    for (final row in meetingRows) {
      bySite[row.siteName] = (bySite[row.siteName] ?? 0) + 1;
      byDate[row.date] = (byDate[row.date] ?? 0) + 1;
    }
    final meetings = SafetyMeetingMetrics(
      completedCount: meetingRows
          .where((r) => r.status == DailySafetyMeetingStatus.completed)
          .length,
      inProgressCount: meetingRows
          .where((r) => r.status == DailySafetyMeetingStatus.inProgress)
          .length,
      bySite: bySite,
      byDate: byDate,
    );

    final allAttendance = attendanceByMeeting.expand((a) => a).toList();
    final attendance = AttendanceMetrics(
      presentCount: allAttendance
          .where((a) => a.status == MeetingAttendanceStatus.present)
          .length,
      absentCount: allAttendance
          .where((a) => a.status == MeetingAttendanceStatus.absent)
          .length,
    );

    final allConcerns = concernsByMeeting.expand((c) => c).toList();
    final concerns = ConcernMetrics(
      totalCount: allConcerns.length,
      openCount: allConcerns
          .where((c) => c.status == MeetingConcernStatus.open)
          .length,
      byCategory: {
        for (final category in MeetingConcernCategory.values)
          category: allConcerns.where((c) => c.category == category).length,
      },
    );

    final now = DateTime.now();
    final correctiveActions = CorrectiveActionMetrics(
      totalCount: actionRows.length,
      openCount: actionRows
          .where((r) => r.status == CorrectiveActionStatus.open)
          .length,
      inProgressCount: actionRows
          .where((r) => r.status == CorrectiveActionStatus.inProgress)
          .length,
      completedCount: actionRows
          .where((r) => r.status == CorrectiveActionStatus.completed)
          .length,
      overdueCount: actionRows.where((r) => r.isOverdueAsOf(now)).length,
    );

    final safetyAlerts = SafetyAlertMetrics(
      activeCount: alertRows
          .where((r) => r.status == SafetyAlertStatus.active)
          .length,
      acknowledgedCount: alertRows
          .where((r) => r.status == SafetyAlertStatus.acknowledged)
          .length,
      resolvedCount: alertRows
          .where((r) => r.status == SafetyAlertStatus.resolved)
          .length,
      bySeverity: {
        for (final severity in SafetyAlertSeverity.values)
          severity: alertRows.where((r) => r.severity == severity).length,
      },
      byCategory: {
        for (final category in SafetyAlertCategory.values)
          category: alertRows.where((r) => r.category == category).length,
      },
    );

    final safetyLearning = SafetyLearningMetrics(
      assignedCount: learningRows.fold<int>(
        0,
        (sum, r) => sum + r.requiredCount,
      ),
      completedCount: learningRows.fold<int>(
        0,
        (sum, r) => sum + r.completedCount,
      ),
      inProgressCount: learningRows.fold<int>(
        0,
        (sum, r) => sum + r.inProgressCount,
      ),
      outstandingCount: learningRows.fold<int>(
        0,
        (sum, r) => sum + r.outstandingCount,
      ),
    );

    return AnalyticsDashboard(
      meetings: meetings,
      attendance: attendance,
      concerns: concerns,
      correctiveActions: correctiveActions,
      safetyAlerts: safetyAlerts,
      safetyLearning: safetyLearning,
    );
  }
}
