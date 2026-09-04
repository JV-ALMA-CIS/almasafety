/// The four report categories this foundation supports. Mirrors
/// `SafetyAlertCategory`'s style: a small fixed set, not user-extensible.
enum ReportCategory {
  dailySafetyMeetings,
  safetyAlerts,
  correctiveActions,
  safetyLearning;

  String get label => switch (this) {
    ReportCategory.dailySafetyMeetings => 'Daily Safety Meetings',
    ReportCategory.safetyAlerts => 'Safety Alerts',
    ReportCategory.correctiveActions => 'Corrective Actions',
    ReportCategory.safetyLearning => 'Safety Learning',
  };
}
