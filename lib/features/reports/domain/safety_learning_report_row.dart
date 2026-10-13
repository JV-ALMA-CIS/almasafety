/// One Safety Learning report row — one worker's compliance summary against
/// the organization's currently-required learning set, built by
/// `ReportsRepository`. See `DailySafetyMeetingReportRow`'s doc comment for
/// why this is a view model rather than a new Firestore-backed type.
///
/// [requiredCount] is the size of the organization-wide required-learning
/// set at the time the report was generated (see
/// `SafetyRequirementRepository.watchResolvedRequiredLearning`, reused
/// unmodified) — the same set `getMyRequiredLearning` materializes records
/// against server-side. [completedCount]/[inProgressCount]/
/// [outstandingCount] are this worker's own [WorkerLearningRecord] statuses
/// against that set; they always sum to [requiredCount] once every required
/// item has at least a lazily-materialized `assigned` record, but may sum to
/// less than [requiredCount] for a worker who has never opened "My Safety
/// Learning" yet (no records materialized) — the shortfall is still
/// correctly counted as outstanding by [outstandingCount], which is derived
/// as `requiredCount - completedCount - inProgressCount`, not from a
/// separate query.
class SafetyLearningReportRow {
  const SafetyLearningReportRow({
    required this.workerUid,
    this.workerName,
    required this.requiredCount,
    required this.completedCount,
    required this.inProgressCount,
  });

  final String workerUid;

  /// The worker's name as shown on the report; null when unknown.
  final String? workerName;
  final int requiredCount;
  final int completedCount;
  final int inProgressCount;

  /// Required items with no completed/in-progress record yet — includes
  /// both `assigned` records and required items with no record at all.
  int get outstandingCount {
    final outstanding = requiredCount - completedCount - inProgressCount;
    return outstanding < 0 ? 0 : outstanding;
  }
}
