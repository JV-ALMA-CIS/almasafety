import '../../safety_alerts/domain/safety_alert_category.dart';
import '../../safety_alerts/domain/safety_alert_severity.dart';

/// Safety Alert metrics for the Analytics dashboard — a pure aggregation
/// over [SafetyAlertReportRow]s already assembled by `ReportsRepository`,
/// computed by `AnalyticsRepository`. See `SafetyMeetingMetrics`'s doc
/// comment for why this is a view model, not a Firestore-backed type.
class SafetyAlertMetrics {
  const SafetyAlertMetrics({
    required this.activeCount,
    required this.acknowledgedCount,
    required this.resolvedCount,
    required this.bySeverity,
    required this.byCategory,
  });

  final int activeCount;
  final int acknowledgedCount;
  final int resolvedCount;

  int get totalCount => activeCount + acknowledgedCount + resolvedCount;

  /// Alert count keyed by [SafetyAlertSeverity] — every severity present,
  /// including zero-count ones, mirroring [ConcernMetrics.byCategory].
  final Map<SafetyAlertSeverity, int> bySeverity;

  /// Alert count keyed by [SafetyAlertCategory] — every category present,
  /// including zero-count ones.
  final Map<SafetyAlertCategory, int> byCategory;
}
