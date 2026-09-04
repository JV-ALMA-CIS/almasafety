/// The severity of one `SafetyAlert`. Mirrors `CorrectiveActionStatus`'s
/// style.
enum SafetyAlertSeverity {
  low,
  medium,
  high,
  critical;

  /// The value stored in Firestore.
  String get id => name;

  String get label => switch (this) {
    SafetyAlertSeverity.low => 'Low',
    SafetyAlertSeverity.medium => 'Medium',
    SafetyAlertSeverity.high => 'High',
    SafetyAlertSeverity.critical => 'Critical',
  };

  /// Parses a stored value, returning null when [id] is unrecognised.
  ///
  /// Never falls back to a default: an unknown value must not be coerced
  /// into any one severity.
  static SafetyAlertSeverity? tryFromId(String? id) {
    if (id == null) return null;
    for (final severity in SafetyAlertSeverity.values) {
      if (severity.id == id) return severity;
    }
    return null;
  }
}
