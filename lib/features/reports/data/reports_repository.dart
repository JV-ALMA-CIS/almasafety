import '../../../core/services/firestore_service.dart';
import '../../authentication/data/account_approval_service.dart';
import '../../authentication/domain/account_status.dart';
import '../../corrective_actions/data/corrective_action_repository.dart';
import '../../daily_safety_meetings/data/daily_safety_meeting_repository.dart';
import '../../daily_safety_meetings/data/meeting_attendance_repository.dart';
import '../../daily_safety_meetings/data/meeting_concern_repository.dart';
import '../../daily_safety_meetings/domain/meeting_attendance_status.dart';
import '../../organizations/data/project_repository.dart';
import '../../organizations/data/site_repository.dart';
import '../../safety_alerts/data/safety_alert_repository.dart';
import '../../safety_learning/data/worker_learning_repository.dart';
import '../../safety_learning/domain/worker_learning_status.dart';
import '../../safety_requirements/data/safety_requirement_repository.dart';
import '../domain/corrective_action_report_row.dart';
import '../domain/daily_safety_meeting_report_row.dart';
import '../domain/safety_alert_report_row.dart';
import '../domain/safety_learning_report_row.dart';

/// Assembles the four report views this foundation provides, entirely from
/// data already readable through existing, unmodified repositories and
/// services.
///
/// **Read-only, by construction.** This class holds no write method of any
/// kind — every field it exposes is a `Future<List<...>>` built from
/// `watchForOrganization`/`watchAll`-style streams already used elsewhere in
/// this codebase (`DailySafetyMeetingRepository.watchAll`,
/// `MeetingAttendanceRepository.watchAll`, `MeetingConcernRepository.watchAll`,
/// `CorrectiveActionRepository.watchForOrganization`,
/// `SafetyAlertRepository.watchForOrganization`,
/// `WorkerLearningRepository.watchForOrganization`,
/// `SafetyRequirementRepository.watchResolvedRequiredLearning`). There is no
/// new Firestore collection, no new callable and no new authorization
/// concept anywhere in this feature — every one of these reads is already
/// gated by `firestore.rules`' existing `belongsToOrganization` grant on
/// each collection, so organization isolation is inherited, not
/// re-implemented.
///
/// Scoped to one organization at a time by construction, matching every
/// other repository in this codebase — there is no method here that could
/// read a second organization's data, by any argument.
class ReportsRepository {
  ReportsRepository({
    required this._firestoreService,
    required this._organizationId,
    AccountApprovalService? accountApprovalService,
  }) : _accountApprovalService =
           accountApprovalService ?? AccountApprovalService();

  final FirestoreService _firestoreService;
  final String _organizationId;
  final AccountApprovalService _accountApprovalService;

  /// The organization this repository is scoped to.
  String get organizationId => _organizationId;

  /// Builds the Daily Safety Meeting report: one row per meeting, with
  /// project/site names resolved and attendance/concern/corrective-action
  /// counts attached.
  ///
  /// [projectId]/[siteId], when given, narrow the result to that project or
  /// site — filtered client-side against already-organization-scoped data,
  /// mirroring how every other filtered screen in this codebase (e.g.
  /// `ActivityRepository.watchBySite`) narrows within a single organization
  /// query rather than adding a cross-organization one. [from]/[to], when
  /// given, narrow to meetings whose `date` falls within that INCLUSIVE
  /// range (compared as `yyyy-MM-dd` strings, matching
  /// `DailySafetyMeeting.date`'s own stored format).
  Future<List<DailySafetyMeetingReportRow>> buildDailySafetyMeetingReport({
    String? projectId,
    String? siteId,
    DateTime? from,
    DateTime? to,
  }) async {
    final meetingRepository = DailySafetyMeetingRepository(
      firestoreService: _firestoreService,
      organizationId: _organizationId,
    );
    final projectRepository = ProjectRepository(
      firestoreService: _firestoreService,
      organizationId: _organizationId,
    );
    final siteRepository = SiteRepository(
      firestoreService: _firestoreService,
      organizationId: _organizationId,
    );

    final allMeetings = await meetingRepository.watchAll().first;
    final projects = await projectRepository.watchAll().first;
    final sites = await siteRepository.watchAll().first;
    final projectNamesById = {for (final p in projects) p.id: p.name};
    final siteNamesById = {for (final s in sites) s.id: s.name};

    final fromKey = from == null ? null : _dateKey(from);
    final toKey = to == null ? null : _dateKey(to);

    final meetings = allMeetings.where((meeting) {
      if (projectId != null && meeting.projectId != projectId) return false;
      if (siteId != null && meeting.siteId != siteId) return false;
      if (fromKey != null && meeting.date.compareTo(fromKey) < 0) return false;
      if (toKey != null && meeting.date.compareTo(toKey) > 0) return false;
      return true;
    }).toList();

    final rows = await Future.wait(
      meetings.map((meeting) async {
        final attendanceRepository = MeetingAttendanceRepository(
          firestoreService: _firestoreService,
          organizationId: _organizationId,
          meetingId: meeting.id,
        );
        final concernRepository = MeetingConcernRepository(
          firestoreService: _firestoreService,
          organizationId: _organizationId,
          meetingId: meeting.id,
        );
        final attendance = await attendanceRepository.watchAll().first;
        final concerns = await concernRepository.watchAll().first;

        return DailySafetyMeetingReportRow(
          meetingId: meeting.id,
          projectId: meeting.projectId,
          projectName: projectNamesById[meeting.projectId] ?? meeting.projectId,
          siteId: meeting.siteId,
          siteName: siteNamesById[meeting.siteId] ?? meeting.siteId,
          date: meeting.date,
          status: meeting.status,
          foremanId: meeting.foremanId,
          activityCount: meeting.activityIds.length,
          meetingPointCount: meeting.meetingPointIds.length,
          presentCount: attendance
              .where((a) => a.status == MeetingAttendanceStatus.present)
              .length,
          absentCount: attendance
              .where((a) => a.status == MeetingAttendanceStatus.absent)
              .length,
          concernCount: concerns.length,
          correctiveActionCount: meeting.correctiveActionIds.length,
        );
      }),
    );

    rows.sort((a, b) => b.date.compareTo(a.date));
    return rows;
  }

  /// Builds the Safety Alerts report: one row per alert, with the site name
  /// resolved. [siteId]/[from]/[to] narrow the result exactly like
  /// [buildDailySafetyMeetingReport], with [from]/[to] compared against
  /// [SafetyAlert.createdAt] using [_isWithinInclusiveDateRange] — so an
  /// alert created at any time of day ON [to] is included, not just those at
  /// or before midnight.
  Future<List<SafetyAlertReportRow>> buildSafetyAlertsReport({
    String? siteId,
    DateTime? from,
    DateTime? to,
  }) async {
    final alertRepository = SafetyAlertRepository(
      firestoreService: _firestoreService,
      organizationId: _organizationId,
    );
    final siteRepository = SiteRepository(
      firestoreService: _firestoreService,
      organizationId: _organizationId,
    );

    final alerts = await alertRepository.watchForOrganization().first;
    final sites = await siteRepository.watchAll().first;
    final siteNamesById = {for (final s in sites) s.id: s.name};

    final rows = alerts
        .where((alert) {
          if (siteId != null && alert.siteId != siteId) return false;
          return _isWithinInclusiveDateRange(alert.createdAt, from, to);
        })
        .map(
          (alert) => SafetyAlertReportRow(
            alertId: alert.id,
            siteId: alert.siteId,
            siteName: siteNamesById[alert.siteId] ?? alert.siteId,
            severity: alert.severity,
            category: alert.category,
            status: alert.status,
            createdAt: alert.createdAt,
            resolvedAt: alert.resolvedAt,
          ),
        )
        .toList();

    rows.sort((a, b) {
      final aDate = a.createdAt;
      final bDate = b.createdAt;
      if (aDate == null || bDate == null) return 0;
      return bDate.compareTo(aDate);
    });
    return rows;
  }

  /// Builds the Corrective Actions report: one row per action, with the
  /// site name resolved. [siteId]/[from]/[to] narrow the result exactly
  /// like [buildDailySafetyMeetingReport], with [from]/[to] compared
  /// against [CorrectiveAction.dueDate] using [_isWithinInclusiveDateRange]
  /// — so an action due at any time of day ON [to] is included, not just
  /// those at or before midnight.
  Future<List<CorrectiveActionReportRow>> buildCorrectiveActionsReport({
    String? siteId,
    DateTime? from,
    DateTime? to,
  }) async {
    final actionRepository = CorrectiveActionRepository(
      firestoreService: _firestoreService,
      organizationId: _organizationId,
    );
    final siteRepository = SiteRepository(
      firestoreService: _firestoreService,
      organizationId: _organizationId,
    );

    final actions = await actionRepository.watchForOrganization().first;
    final sites = await siteRepository.watchAll().first;
    final siteNamesById = {for (final s in sites) s.id: s.name};

    // Names for actions created before names were stored on the action.
    final peopleNames = <String, String>{};
    try {
      for (final user in await _accountApprovalService.listUsers(
        organizationId: _organizationId,
      )) {
        if (user.name.trim().isNotEmpty) peopleNames[user.uid] = user.name;
      }
    } on Object {
      // The report still renders, with "Unknown person" where needed.
    }
    final rows = actions
        .where((action) {
          if (siteId != null && action.siteId != siteId) return false;
          return _isWithinInclusiveDateRange(action.dueDate, from, to);
        })
        .map(
          (action) => CorrectiveActionReportRow(
            actionId: action.id,
            siteId: action.siteId,
            siteName: siteNamesById[action.siteId] ?? 'Unknown site',
            title: action.title,
            assignedTo: action.assignedTo,
            assignedToName:
                action.assignedToName ??
                peopleNames[action.assignedTo] ??
                'Unknown person',
            dueDate: action.dueDate,
            status: action.status,
          ),
        )
        .toList();

    rows.sort((a, b) => a.dueDate.compareTo(b.dueDate));
    return rows;
  }

  /// Builds the Safety Learning report: one row per active worker in this
  /// organization, summarizing their progress against THEIR OWN
  /// currently-required learning set. Reuses
  /// [SafetyRequirementRepository.watchResolvedRequiredLearning] unmodified,
  /// once per worker — the exact same required-set resolution
  /// `getMyRequiredLearning` materializes records against server-side — so
  /// this report can never claim a different "required" set than the one
  /// that actually governs a worker's obligations. Now that a requirement
  /// can be site/activity-scoped (not just organization-wide), two workers
  /// can have different required counts, so this is resolved per worker
  /// rather than once for the whole organization.
  Future<List<SafetyLearningReportRow>> buildSafetyLearningReport() async {
    final requirementRepository = SafetyRequirementRepository(
      firestoreService: _firestoreService,
      organizationId: _organizationId,
    );
    final workerLearningRepository = WorkerLearningRepository(
      firestoreService: _firestoreService,
      organizationId: _organizationId,
    );

    final workers = await _accountApprovalService.listUsers(
      status: AccountStatus.active,
      organizationId: _organizationId,
    );
    final records = await workerLearningRepository.watchForOrganization().first;

    final rows = await Future.wait(
      workers.map((worker) async {
        final requiredLearning = await requirementRepository
            .watchResolvedRequiredLearning(worker.uid)
            .first;
        final ownRecords = records.where((r) => r.workerUid == worker.uid);
        final completedCount = ownRecords
            .where((r) => r.status == WorkerLearningStatus.completed)
            .length;
        final inProgressCount = ownRecords
            .where((r) => r.status == WorkerLearningStatus.inProgress)
            .length;

        return SafetyLearningReportRow(
          workerUid: worker.uid,
          workerName: worker.name.trim().isEmpty ? null : worker.name.trim(),
          requiredCount: requiredLearning.length,
          completedCount: completedCount,
          inProgressCount: inProgressCount,
        );
      }),
    );

    rows.sort(
      (a, b) => (a.workerName ?? '').toLowerCase().compareTo(
        (b.workerName ?? '').toLowerCase(),
      ),
    );
    return rows;
  }
}

String _dateKey(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}

/// Whether [value] falls within the inclusive `[from, to]` date range,
/// treating [to] as the WHOLE of that calendar day rather than the instant
/// `showDateRangePicker` actually returns it as (midnight at the start of
/// the selected end day).
///
/// The single shared filter behind [ReportsRepository.buildSafetyAlertsReport]
/// and [ReportsRepository.buildCorrectiveActionsReport] — centralized here
/// rather than duplicated per report so a future report gets the same
/// inclusive-end-date behavior for free, and so `AnalyticsRepository`
/// (which composes both of those methods rather than re-filtering) inherits
/// the fix automatically without any change of its own.
///
/// Compares against an EXCLUSIVE upper bound — the start of the day after
/// [to] — rather than an inclusive `isAfter(to)` check, so a [value] any
/// time during [to]'s calendar day (not just before its literal midnight
/// timestamp) is included. A null [value] never matches a bounded range,
/// mirroring the previous `createdAt == null` exclusion.
bool _isWithinInclusiveDateRange(
  DateTime? value,
  DateTime? from,
  DateTime? to,
) {
  if (from == null && to == null) return true;
  if (value == null) return false;
  if (from != null && value.isBefore(from)) return false;
  if (to != null) {
    final exclusiveUpperBound = DateTime(to.year, to.month, to.day + 1);
    if (!value.isBefore(exclusiveUpperBound)) return false;
  }
  return true;
}
