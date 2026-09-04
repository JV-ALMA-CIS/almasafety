import 'attendance_metrics.dart';
import 'concern_metrics.dart';
import 'corrective_action_metrics.dart';
import 'safety_alert_metrics.dart';
import 'safety_learning_metrics.dart';
import 'safety_meeting_metrics.dart';

/// The full Analytics dashboard snapshot — all six metric groups this
/// foundation supports, for one filtered generation. Built by
/// `AnalyticsRepository.build`.
class AnalyticsDashboard {
  const AnalyticsDashboard({
    required this.meetings,
    required this.attendance,
    required this.concerns,
    required this.correctiveActions,
    required this.safetyAlerts,
    required this.safetyLearning,
  });

  final SafetyMeetingMetrics meetings;
  final AttendanceMetrics attendance;
  final ConcernMetrics concerns;
  final CorrectiveActionMetrics correctiveActions;
  final SafetyAlertMetrics safetyAlerts;
  final SafetyLearningMetrics safetyLearning;
}
