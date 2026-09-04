/// The lifecycle status of one `CorrectiveAction`. Mirrors
/// `DailySafetyMeetingStatus`'s style.
///
/// Unlike [DailySafetyMeetingStatus.completed], [overdue] is not a terminal
/// state reachable only by time passing — it is a status an authorized
/// supervisor/manager sets explicitly through `updateCorrectiveActionStatus`,
/// exactly like every other transition here. There is deliberately no
/// scheduled function that flips a past-due action to [overdue]
/// automatically; that kind of background job is out of scope for this
/// stage (see this feature's "Do NOT implement: Notifications" boundary).
enum CorrectiveActionStatus {
  open,
  inProgress,
  completed,
  overdue;

  /// The value stored in Firestore.
  String get id => name;

  String get label => switch (this) {
    CorrectiveActionStatus.open => 'Open',
    CorrectiveActionStatus.inProgress => 'In Progress',
    CorrectiveActionStatus.completed => 'Completed',
    CorrectiveActionStatus.overdue => 'Overdue',
  };

  bool get isTerminal => this == CorrectiveActionStatus.completed;

  /// Parses a stored value, returning null when [id] is unrecognised.
  ///
  /// Never falls back to a default: an unknown value must not be coerced
  /// into any one status.
  static CorrectiveActionStatus? tryFromId(String? id) {
    if (id == null) return null;
    for (final status in CorrectiveActionStatus.values) {
      if (status.id == id) return status;
    }
    return null;
  }
}
