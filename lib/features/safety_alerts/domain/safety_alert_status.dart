/// The lifecycle status of one `SafetyAlert`. Mirrors
/// `CorrectiveActionStatus`'s style.
///
/// `active` -> `acknowledged` -> `resolved` is the intended progression, but
/// nothing here enforces that ordering server-side beyond what
/// `acknowledgeSafetyAlert`/`resolveSafetyAlert` each individually require
/// (see `safety_alert_callable.ts`) — there is no separate "skip
/// acknowledged and resolve directly" refusal, matching how
/// `CorrectiveActionStatus` transitions are similarly unconstrained beyond
/// their own callable's precondition.
enum SafetyAlertStatus {
  active,
  acknowledged,
  resolved;

  /// The value stored in Firestore.
  String get id => name;

  String get label => switch (this) {
    SafetyAlertStatus.active => 'Active',
    SafetyAlertStatus.acknowledged => 'Acknowledged',
    SafetyAlertStatus.resolved => 'Resolved',
  };

  bool get isTerminal => this == SafetyAlertStatus.resolved;

  /// Parses a stored value, returning null when [id] is unrecognised.
  ///
  /// Never falls back to a default: an unknown value must not be coerced
  /// into any one status.
  static SafetyAlertStatus? tryFromId(String? id) {
    if (id == null) return null;
    for (final status in SafetyAlertStatus.values) {
      if (status.id == id) return status;
    }
    return null;
  }
}
