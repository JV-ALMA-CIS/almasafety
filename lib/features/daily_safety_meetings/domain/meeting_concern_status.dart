/// The lifecycle status of one [MeetingConcern]. Mirrors
/// [MeetingAttendanceStatus]'s style.
enum MeetingConcernStatus {
  open,
  resolved;

  /// The value stored in Firestore.
  String get id => name;

  String get label => switch (this) {
    MeetingConcernStatus.open => 'Open',
    MeetingConcernStatus.resolved => 'Resolved',
  };

  /// Parses a stored value, returning null when [id] is unrecognised.
  ///
  /// Never falls back to a default: an unknown value must not be coerced
  /// into either state.
  static MeetingConcernStatus? tryFromId(String? id) {
    if (id == null) return null;
    for (final status in MeetingConcernStatus.values) {
      if (status.id == id) return status;
    }
    return null;
  }
}
