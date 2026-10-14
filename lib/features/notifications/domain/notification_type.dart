/// The type of one `AppNotification` — what feature it relates to. Mirrors
/// `SafetyAlertCategory`'s style: a small fixed set, not user-extensible.
///
/// Named `NotificationType` in the data model, exposed here as
/// [AppNotificationType] to avoid colliding with Flutter's own
/// `dart:ui`-adjacent `NotificationListener`/platform notification
/// vocabulary — there is no actual name clash in this SDK today, but every
/// other domain enum in this codebase is prefixed with its owning model
/// (`MeetingConcernStatus`, `CorrectiveActionStatus`, `SafetyAlertStatus`),
/// so this one follows suit as `AppNotificationType` to stay consistent.
enum AppNotificationType {
  safetyAlert,
  correctiveAction,
  safetyMeeting,
  safetyLearning,
  hazard,
  incident,
  inspection,
  riskAssessment,
  system;

  /// The value stored in Firestore.
  String get id => name;

  String get label => switch (this) {
    AppNotificationType.safetyAlert => 'Safety Alert',
    AppNotificationType.correctiveAction => 'Corrective Action',
    AppNotificationType.safetyMeeting => 'Safety Meeting',
    AppNotificationType.safetyLearning => 'Safety Learning',
    AppNotificationType.hazard => 'Hazard',
    AppNotificationType.incident => 'Incident',
    AppNotificationType.inspection => 'Inspection',
    AppNotificationType.riskAssessment => 'Risk Assessment',
    AppNotificationType.system => 'System',
  };

  /// Parses a stored value, returning null when [id] is unrecognised.
  ///
  /// Never falls back to a default: an unknown value must not be coerced
  /// into any one type.
  static AppNotificationType? tryFromId(String? id) {
    if (id == null) return null;
    for (final type in AppNotificationType.values) {
      if (type.id == id) return type;
    }
    return null;
  }
}
