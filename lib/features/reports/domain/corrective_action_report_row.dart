import '../../corrective_actions/domain/corrective_action_status.dart';

/// One Corrective Actions report row — a thin, read-only projection of a
/// [CorrectiveAction] built by `ReportsRepository`. See
/// [DailySafetyMeetingReportRow]'s doc comment for why this is a view model
/// rather than a new Firestore-backed type.
class CorrectiveActionReportRow {
  const CorrectiveActionReportRow({
    required this.actionId,
    required this.siteId,
    required this.siteName,
    required this.title,
    required this.assignedTo,
    this.assignedToName = 'Unknown person',
    required this.dueDate,
    required this.status,
  });

  final String actionId;
  final String siteId;
  final String siteName;
  final String title;
  final String assignedTo;

  /// The assignee's name as shown on the report.
  final String assignedToName;
  final DateTime dueDate;
  final CorrectiveActionStatus status;

  /// Whether this action is overdue RIGHT NOW: past its [dueDate] and not
  /// yet [CorrectiveActionStatus.completed]. Computed independently of the
  /// stored `overdue` status value — that status is only ever set manually
  /// by an authorized updater (see `CorrectiveActionStatus`'s doc comment
  /// in the domain source), so an action can be past-due in reality before
  /// anyone has flagged it. This report treats "overdue" as a derived fact,
  /// not a trusted status label, for the purposes of the overdue count.
  bool isOverdueAsOf(DateTime now) {
    return status != CorrectiveActionStatus.completed && dueDate.isBefore(now);
  }
}
