import '../../safety_alerts/domain/safety_alert_category.dart';
import '../../safety_alerts/domain/safety_alert_severity.dart';
import '../../safety_alerts/domain/safety_alert_status.dart';

/// One Safety Alerts report row — a thin, read-only projection of a
/// [SafetyAlert] built by `ReportsRepository`. See
/// [DailySafetyMeetingReportRow]'s doc comment for why this is a view model
/// rather than a new Firestore-backed type.
class SafetyAlertReportRow {
  const SafetyAlertReportRow({
    required this.alertId,
    required this.siteId,
    required this.siteName,
    required this.severity,
    required this.category,
    required this.status,
    required this.createdAt,
    this.resolvedAt,
  });

  final String alertId;
  final String siteId;
  final String siteName;
  final SafetyAlertSeverity severity;
  final SafetyAlertCategory category;
  final SafetyAlertStatus status;
  final DateTime? createdAt;
  final DateTime? resolvedAt;
}
