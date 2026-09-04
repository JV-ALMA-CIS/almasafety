/// The attendance status of one worker on one [MeetingAttendance] record.
/// Mirrors [DailySafetyMeetingStatus]'s style.
enum MeetingAttendanceStatus {
  present,
  absent;

  /// The value stored in Firestore.
  String get id => name;

  String get label => switch (this) {
    MeetingAttendanceStatus.present => 'Present',
    MeetingAttendanceStatus.absent => 'Absent',
  };

  /// Parses a stored value, returning null when [id] is unrecognised.
  ///
  /// Never falls back to a default: an unknown value must not be coerced
  /// into either state.
  static MeetingAttendanceStatus? tryFromId(String? id) {
    if (id == null) return null;
    for (final status in MeetingAttendanceStatus.values) {
      if (status.id == id) return status;
    }
    return null;
  }
}
