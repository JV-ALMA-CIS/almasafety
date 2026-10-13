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
///
/// [submittedForReview] is the "assignee reports done" half of the
/// completion split: the action's own `assignedTo` moves `open`/
/// `inProgress` here themselves, through `submitCorrectiveActionForReview`.
/// [completed] — "a reviewer verified that claim" — is then only reachable
/// FROM [submittedForReview] via `updateCorrectiveActionStatus`, never
/// directly from `open`/`inProgress`. A reviewer who disagrees with the
/// claim moves it back to `open`/`inProgress` instead of completing it —
/// there is no separate "rejected" status.
enum CorrectiveActionStatus {
  open,
  inProgress,
  submittedForReview,
  completed,
  overdue;

  /// The value stored in Firestore.
  String get id => name;

  String get label => switch (this) {
    CorrectiveActionStatus.open => 'Open',
    CorrectiveActionStatus.inProgress => 'In Progress',
    CorrectiveActionStatus.submittedForReview => 'Submitted for Review',
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
