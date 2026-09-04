/// Safety Meeting metrics for the Analytics dashboard — a pure aggregation
/// over [DailySafetyMeetingReportRow]s already assembled by
/// `ReportsRepository`, computed by `AnalyticsRepository`.
///
/// **A view model, not a Firestore-backed domain type.** Nothing here is
/// parsed from a document or written anywhere — see
/// `DailySafetyMeetingReportRow`'s doc comment for why every metric model
/// in this feature follows the same shape.
class SafetyMeetingMetrics {
  const SafetyMeetingMetrics({
    required this.completedCount,
    required this.inProgressCount,
    required this.bySite,
    required this.byDate,
  });

  final int completedCount;
  final int inProgressCount;

  int get totalCount => completedCount + inProgressCount;

  /// Meeting count keyed by site name, most-meetings-first is NOT applied
  /// here — ordering is the presentation layer's job; this is a plain
  /// count map.
  final Map<String, int> bySite;

  /// Meeting count keyed by the meeting's own `yyyy-MM-dd` date string.
  final Map<String, int> byDate;
}
