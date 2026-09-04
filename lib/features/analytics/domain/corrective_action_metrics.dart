/// Corrective Action metrics for the Analytics dashboard — a pure
/// aggregation over [CorrectiveActionReportRow]s already assembled by
/// `ReportsRepository`, computed by `AnalyticsRepository`. See
/// `SafetyMeetingMetrics`'s doc comment for why this is a view model, not a
/// Firestore-backed type.
class CorrectiveActionMetrics {
  const CorrectiveActionMetrics({
    required this.totalCount,
    required this.openCount,
    required this.inProgressCount,
    required this.completedCount,
    required this.overdueCount,
  });

  final int totalCount;
  final int openCount;
  final int inProgressCount;
  final int completedCount;

  /// Actions past their due date and not yet completed, computed via
  /// `CorrectiveActionReportRow.isOverdueAsOf` — the same derived-not-
  /// trusted-status rule the Reports feature already uses, reused rather
  /// than re-defined here.
  final int overdueCount;

  /// Completed as a percentage of total, `0` when there are no actions at
  /// all (never divides by zero).
  double get completionRate {
    if (totalCount == 0) return 0;
    return completedCount / totalCount * 100;
  }
}
