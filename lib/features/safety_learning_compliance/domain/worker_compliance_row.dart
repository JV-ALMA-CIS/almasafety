import '../../safety_learning/domain/safety_learning.dart';

/// One worker's Safety Learning compliance for one activity they are
/// assigned to at one site — the row [SafetyComplianceRepository] builds and
/// [SafetyLearningComplianceScreen] renders.
///
/// **Not a new resolution concept.** [requiredLearning] is exactly the
/// output of `SafetyRequirementRepository.watchResolvedRequiredLearning`
/// (the same site/activity-aware resolver `MySafetyLearningScreen` and the
/// Daily Safety Meeting gate both already use) for this worker, within this
/// organization — this class only adds the activity/site context a
/// compliance view needs and separates [requiredLearning] into
/// [completedLearning]/[outstandingLearning] using the worker's own
/// [WorkerLearningRecord]s, exactly as `WorkerLearningStatus.completed`
/// already defines "completed" everywhere else in this codebase.
class WorkerComplianceRow {
  const WorkerComplianceRow({
    required this.workerUid,
    required this.workerName,
    required this.workerTypeLabel,
    required this.roleLabel,
    required this.siteId,
    required this.activityId,
    required this.activityName,
    this.unassignedToActivity = false,
    required this.requiredLearning,
    required this.completedLearning,
    required this.completedAtByLearningId,
  });

  final String workerUid;
  final String workerName;

  /// e.g. "JVA Employee", "Contractor" — from `Membership.workerType`, where
  /// already available (optional, per the task's own "where already
  /// available" wording — never invented when absent).
  final String? workerTypeLabel;

  /// e.g. "Worker", "Foreman" — from the worker's own membership role.
  final String? roleLabel;

  final String siteId;
  final String activityId;
  final String activityName;

  /// True for a worker who belongs to this site (per their own membership
  /// `siteIds`) but has not yet been assigned to any activity here — grouped
  /// under a synthetic "Not assigned to an activity" bucket instead of being
  /// silently dropped from the compliance view (they are a real worker at
  /// this site; the Foreman just hasn't picked which activity they're doing
  /// yet).
  final bool unassignedToActivity;

  /// Every ACTIVE [SafetyLearning] item required of this worker for this
  /// activity/site — see this class's doc comment for the resolution rule.
  final List<SafetyLearning> requiredLearning;

  /// The subset of [requiredLearning] this worker has completed
  /// (`WorkerLearningStatus.completed`).
  final List<SafetyLearning> completedLearning;

  /// Completion timestamps for [completedLearning], by learning id — absent
  /// for an item with no record or without a recorded `completedAt`.
  final Map<String, DateTime> completedAtByLearningId;

  int get requiredCount => requiredLearning.length;
  int get completedCount => completedLearning.length;

  /// The required items NOT in [completedLearning] — an `assigned`/
  /// `inProgress` record, or no record at all, both count as outstanding,
  /// matching `SafetyLearningReportRow.outstandingCount`'s existing
  /// definition of "outstanding" elsewhere in this codebase.
  List<SafetyLearning> get outstandingLearning {
    final completedIds = completedLearning.map((l) => l.id).toSet();
    return [
      for (final learning in requiredLearning)
        if (!completedIds.contains(learning.id)) learning,
    ];
  }

  int get outstandingCount => requiredCount - completedCount;

  /// Ready = every required item is completed. A worker with nothing
  /// required of them for this activity is vacuously Ready — matching
  /// `requireForemanLearningComplete`'s own "nothing required, never
  /// blocked" rule.
  bool get isReady => outstandingCount == 0;
}
