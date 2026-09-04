/// The category of one [MeetingConcern]. Mirrors [MeetingConcernStatus]'s
/// style. Deliberately a small fixed set for field use — not user-extensible
/// at this stage, matching how [DailySafetyMeetingStatus] has no admin-
/// configurable values either.
enum MeetingConcernCategory {
  safety,
  equipment,
  environment,
  worker,
  other;

  /// The value stored in Firestore.
  String get id => name;

  String get label => switch (this) {
    MeetingConcernCategory.safety => 'Safety',
    MeetingConcernCategory.equipment => 'Equipment',
    MeetingConcernCategory.environment => 'Environment',
    MeetingConcernCategory.worker => 'Worker',
    MeetingConcernCategory.other => 'Other',
  };

  /// Parses a stored value, returning null when [id] is unrecognised.
  ///
  /// Never falls back to a default: an unknown value must not be coerced
  /// into any one category.
  static MeetingConcernCategory? tryFromId(String? id) {
    if (id == null) return null;
    for (final category in MeetingConcernCategory.values) {
      if (category.id == id) return category;
    }
    return null;
  }
}
