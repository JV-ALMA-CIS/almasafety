/// The lifecycle status of one [DailySafetyMeeting]. Mirrors
/// `WorkerLearningStatus`'s style.
///
/// A meeting starts at [inProgress] the moment `createDailySafetyMeeting`
/// runs — the foreman has begun recording it, but may still
/// accept/remove/add activities and meeting points and record concerns —
/// and moves to [completed] once `completeDailySafetyMeeting` runs. There is
/// no third state: this platform does not conduct or transcribe the
/// physical meeting, only records that it happened and what was covered.
enum DailySafetyMeetingStatus {
  inProgress,
  completed;

  /// The value stored in Firestore.
  String get id => name;

  String get label => switch (this) {
    DailySafetyMeetingStatus.inProgress => 'In Progress',
    DailySafetyMeetingStatus.completed => 'Completed',
  };

  /// Parses a stored value, returning null when [id] is unrecognised.
  ///
  /// Never falls back to a default: an unknown value must not be coerced
  /// into [inProgress].
  static DailySafetyMeetingStatus? tryFromId(String? id) {
    if (id == null) return null;
    for (final status in DailySafetyMeetingStatus.values) {
      if (status.id == id) return status;
    }
    return null;
  }
}
