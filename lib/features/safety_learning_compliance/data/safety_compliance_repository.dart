import '../../../core/services/firestore_service.dart';
import '../../activities/data/activity_admin_service.dart';
import '../../activities/data/activity_assignment_repository.dart';
import '../../authentication/data/account_approval_service.dart';
import '../../authentication/domain/account_status.dart';
import '../../safety_learning/data/worker_learning_service.dart';
import '../../safety_learning/domain/safety_learning.dart';
import '../../safety_learning/domain/worker_learning_record.dart';
import '../../safety_learning/domain/worker_learning_status.dart';
import '../../safety_requirements/data/safety_requirement_repository.dart';
import '../domain/activity_compliance_summary.dart';
import '../domain/worker_compliance_row.dart';

/// Builds the Site Manager-facing Safety Learning compliance view — **Site
/// -> Activity -> Workers**, answering "which workers are ready for the
/// work happening at my site, and what are they missing."
///
/// **Not a second interpretation of what learning is required.** Every row
/// this class produces resolves required learning through
/// [SafetyRequirementRepository.watchResolvedRequiredLearning] — the exact
/// same site/activity-aware resolver `MySafetyLearningScreen` and
/// `completeDailySafetyMeeting`'s gate both already use — called once per
/// worker, the same way `ReportsRepository.buildSafetyLearningReport`
/// already does. This class only adds the Site -> Activity grouping, the
/// worker-name/role/type lookup, and the completed/outstanding/Ready split
/// a compliance dashboard needs on top of that existing resolution; it
/// introduces no new Firestore collection and no new authorization concept
/// — every read here already flows through repositories/services an
/// existing screen (`SiteWorkersScreen`, `ActivityWorkersScreen`,
/// `ReportsRepository`) uses today, each already gated by
/// `firestore.rules`'/`approval_callable.ts`'s existing
/// organization-membership checks. A Site Manager's real authorization
/// boundary is the ORGANIZATION they manage (`requireOrganizationScopedManager`'s
/// server-side rule, mirrored by `firestore.rules`' own `siteManager`
/// carve-outs) — site is a within-organization grouping/filter here, exactly
/// like every other Site Manager screen in this codebase (e.g.
/// `SiteWorkersScreen`), not a second, narrower server boundary.
///
/// **Activities are resolved via [ActivityAdminService.getSiteActivities],
/// a read callable** — the one exception to "no new callable" above, added
/// because `firestore.rules` structurally cannot grant a Foreman/Worker a
/// site-scoped LIST query on `activities` (see that rule's own doc comment
/// on why a `resource.data`-dependent branch poisons a query for every
/// caller); this callable is the Admin-SDK equivalent of that same query,
/// scope-checked server-side instead of relying on the rules engine to
/// prove something it cannot prove for this query shape.
///
/// Scoped to one organization at a time by construction, matching
/// [ReportsRepository].
class SafetyComplianceRepository {
  SafetyComplianceRepository({
    required FirestoreService firestoreService,
    required String organizationId,
    ActivityAdminService? activityAdminService,
    ActivityAssignmentRepository? activityAssignmentRepository,
    SafetyRequirementRepository? safetyRequirementRepository,
    WorkerLearningService? workerLearningService,
    AccountApprovalService? accountApprovalService,
  }) : _organizationId = organizationId,
       _activityAdminService = activityAdminService ?? ActivityAdminService(),
       _activityAssignmentRepository =
           activityAssignmentRepository ??
           ActivityAssignmentRepository(
             firestoreService: firestoreService,
             organizationId: organizationId,
           ),
       _safetyRequirementRepository =
           safetyRequirementRepository ??
           SafetyRequirementRepository(
             firestoreService: firestoreService,
             organizationId: organizationId,
           ),
       _workerLearningService =
           workerLearningService ?? WorkerLearningService(),
       _accountApprovalService =
           accountApprovalService ?? AccountApprovalService();

  final String _organizationId;
  final ActivityAdminService _activityAdminService;
  final ActivityAssignmentRepository _activityAssignmentRepository;
  final SafetyRequirementRepository _safetyRequirementRepository;
  final WorkerLearningService _workerLearningService;
  final AccountApprovalService _accountApprovalService;

  /// The organization this repository is scoped to.
  String get organizationId => _organizationId;

  /// Builds one [ActivityComplianceSummary] per ACTIVE activity at [siteId],
  /// each carrying one [WorkerComplianceRow] per worker assigned to that
  /// activity, PLUS (when non-empty) a synthetic "Not assigned to an
  /// activity" summary for workers whose membership already grants them this
  /// site (`OrganizationUser.siteIds`) but who have not yet been assigned to
  /// any activity here.
  ///
  /// That extra bucket matters: a Foreman "adding a worker to a project"
  /// grants site access via `approvePendingAccount`'s `siteIds` — the exact
  /// membership field [MyWorkersScreen] itself filters on — without
  /// necessarily also creating an `activities/{id}/assignments/{uid}`
  /// document (a separate step, done from `ActivityWorkersScreen`). Without
  /// this bucket such a worker is a real member of the site yet invisible
  /// here, which read as "no workers" even though the Foreman's own worker
  /// list showed them.
  ///
  /// A worker assigned to more than one activity at this site appears once
  /// per activity — required learning is resolved per (worker, site,
  /// activity) exactly like everywhere else in this codebase (a Daily
  /// Safety Meeting gate, `MySafetyLearningScreen`'s "why" context), so the
  /// same worker can legitimately be Ready for one activity and Not Ready
  /// for another.
  Future<List<ActivityComplianceSummary>> buildSiteCompliance(
    String siteId,
  ) async {
    // Uses the getSiteActivities callable, not ActivityRepository
    // .watchBySite — that's a collection QUERY, and firestore.rules'
    // `activities/{activityId}` grants only Admin/Site Manager for LIST
    // queries ("rules are not filters": a rule branch that depends on
    // resource.data, like the Foreman/Worker site-scope check, can never
    // be proven safe for a query and would poison it for EVERY caller —
    // see that rule's own doc comment). getSiteActivities re-derives and
    // enforces the same site scope server-side instead, and works
    // identically for every role this screen serves.
    final activities = (await _activityAdminService.getSiteActivities(
      organizationId: _organizationId,
      siteId: siteId,
    )).where((a) => a.status.id == 'active').toList(growable: false);

    final members = await _accountApprovalService.listUsers(
      status: AccountStatus.active,
      organizationId: _organizationId,
    );
    final memberByUid = {for (final member in members) member.uid: member};

    if (activities.isEmpty && !members.any((m) => m.siteIds.contains(siteId))) {
      return const [];
    }

    // Every activity's assignments are resolved FIRST, before fetching any
    // learning records — getCrewLearningRecords is called once, for the
    // full set of relevant worker uids at this site, rather than
    // unconditionally reading every worker_learning_record in the
    // organization the way a direct WorkerLearningRepository.
    // watchForOrganization() read used to. That matters for a Foreman
    // specifically: firestore.rules refuses that unconstrained collection
    // read outright for a Foreman caller (see WorkerLearningService
    // .getCrewLearningRecords's own doc comment), so this must ask only
    // for the uids it actually needs, scoped by the callable server-side.
    final assignmentsByActivity = <String, List<String>>{};
    final assignedUidsAtSite = <String>{};
    for (final activity in activities) {
      final assignments = await _activityAssignmentRepository
          .watchAssignedWorkers(activity.id)
          .first;
      final uids = assignments.map((a) => a.uid).toList(growable: false);
      assignmentsByActivity[activity.id] = uids;
      assignedUidsAtSite.addAll(uids);
    }

    final unassignedMembers = members
        .where(
          (m) =>
              m.siteIds.contains(siteId) && !assignedUidsAtSite.contains(m.uid),
        )
        .toList(growable: false);

    final relevantUids = {
      ...assignedUidsAtSite,
      ...unassignedMembers.map((m) => m.uid),
    };
    final allRecords = await _workerLearningService.getCrewLearningRecords(
      organizationId: _organizationId,
      workerUids: relevantUids.toList(growable: false),
    );
    final recordsByWorker = <String, List<WorkerLearningRecord>>{};
    for (final record in allRecords) {
      (recordsByWorker[record.workerUid] ??= []).add(record);
    }

    // Resolution is cached per worker: a worker assigned to several
    // activities at this site still only calls
    // `watchResolvedRequiredLearning` once — that method's own result
    // already reflects every one of the worker's assignments (their FULL
    // work context), not just one activity, matching how the worker's own
    // `MySafetyLearningScreen` resolves it.
    final requiredByWorker = <String, List<SafetyLearning>>{};

    final summaries = <ActivityComplianceSummary>[];
    for (final activity in activities) {
      final assignedUids = assignmentsByActivity[activity.id]!;

      final rows = <WorkerComplianceRow>[];
      for (final uid in assignedUids) {
        final member = memberByUid[uid];
        final required = requiredByWorker.putIfAbsent(uid, () => []);
        if (required.isEmpty) {
          final resolved = await _safetyRequirementRepository
              .watchResolvedRequiredLearning(uid)
              .first;
          required.addAll(resolved);
        }

        final workerRecords = recordsByWorker[uid] ?? const [];
        final completedIds = {
          for (final record in workerRecords)
            if (record.status == WorkerLearningStatus.completed)
              record.learningId,
        };
        final completedAtByLearningId = {
          for (final record in workerRecords)
            if (record.status == WorkerLearningStatus.completed &&
                record.completedAt != null)
              record.learningId: record.completedAt!,
        };

        rows.add(
          WorkerComplianceRow(
            workerUid: uid,
            workerName: member?.name ?? uid,
            workerTypeLabel: member?.workerType?.label,
            roleLabel: member?.role?.label,
            siteId: siteId,
            activityId: activity.id,
            activityName: activity.name,
            requiredLearning: List.unmodifiable(required),
            completedLearning: [
              for (final learning in required)
                if (completedIds.contains(learning.id)) learning,
            ],
            completedAtByLearningId: completedAtByLearningId,
            quizOutstandingIds: _quizOutstandingIds(workerRecords),
          ),
        );
      }

      rows.sort((a, b) => a.workerName.compareTo(b.workerName));
      summaries.add(
        ActivityComplianceSummary(
          activityId: activity.id,
          activityName: activity.name,
          rows: rows,
        ),
      );
    }

    summaries.sort((a, b) => a.activityName.compareTo(b.activityName));

    if (unassignedMembers.isNotEmpty) {
      final unassignedRows = <WorkerComplianceRow>[];
      for (final member in unassignedMembers) {
        final required = requiredByWorker.putIfAbsent(member.uid, () => []);
        if (required.isEmpty) {
          final resolved = await _safetyRequirementRepository
              .watchResolvedRequiredLearning(member.uid)
              .first;
          required.addAll(resolved);
        }

        final workerRecords = recordsByWorker[member.uid] ?? const [];
        final completedIds = {
          for (final record in workerRecords)
            if (record.status == WorkerLearningStatus.completed)
              record.learningId,
        };
        final completedAtByLearningId = {
          for (final record in workerRecords)
            if (record.status == WorkerLearningStatus.completed &&
                record.completedAt != null)
              record.learningId: record.completedAt!,
        };

        unassignedRows.add(
          WorkerComplianceRow(
            workerUid: member.uid,
            workerName: member.name,
            workerTypeLabel: member.workerType?.label,
            roleLabel: member.role?.label,
            siteId: siteId,
            activityId: '',
            activityName: 'Not assigned to an activity',
            unassignedToActivity: true,
            requiredLearning: List.unmodifiable(required),
            completedLearning: [
              for (final learning in required)
                if (completedIds.contains(learning.id)) learning,
            ],
            completedAtByLearningId: completedAtByLearningId,
            quizOutstandingIds: _quizOutstandingIds(workerRecords),
          ),
        );
      }

      unassignedRows.sort((a, b) => a.workerName.compareTo(b.workerName));
      summaries.add(
        ActivityComplianceSummary(
          activityId: '',
          activityName: 'Not assigned to an activity',
          rows: unassignedRows,
        ),
      );
    }

    return summaries;
  }

  /// Records whose video step is done but which are not complete — only a
  /// mandatory quiz keeps a record there (see `completeLearning`).
  static Set<String> _quizOutstandingIds(List<WorkerLearningRecord> records) =>
      {
        for (final record in records)
          if (record.status == WorkerLearningStatus.inProgress &&
              record.contentCompleted)
            record.learningId,
      };
}
