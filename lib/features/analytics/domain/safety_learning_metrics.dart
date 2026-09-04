/// Safety Learning metrics for the Analytics dashboard — a pure aggregation
/// over [SafetyLearningReportRow]s already assembled by `ReportsRepository`,
/// computed by `AnalyticsRepository`. See `SafetyMeetingMetrics`'s doc
/// comment for why this is a view model, not a Firestore-backed type.
///
/// "Assigned" here is [SafetyLearningReportRow.requiredCount] summed across
/// every worker — the organization-wide required-learning set applied once
/// per worker, matching [SafetyLearningReportRow]'s own doc comment on how
/// that count is derived.
class SafetyLearningMetrics {
  const SafetyLearningMetrics({
    required this.assignedCount,
    required this.completedCount,
    required this.inProgressCount,
    required this.outstandingCount,
  });

  final int assignedCount;
  final int completedCount;
  final int inProgressCount;
  final int outstandingCount;

  /// Completed as a percentage of assigned, `0` when nothing is assigned
  /// at all (never divides by zero).
  double get completionPercentage {
    if (assignedCount == 0) return 0;
    return completedCount / assignedCount * 100;
  }
}
