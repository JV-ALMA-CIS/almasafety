/// The type of one [MeetingEvidence] item. Mirrors
/// [MeetingConcernCategory]'s style: a small fixed set for field use, not
/// user-extensible at this stage.
enum MeetingEvidenceType {
  handwrittenNotes,
  signInSheet,
  briefingPhoto,
  document,
  other;

  /// The value stored in Firestore.
  String get id => name;

  String get label => switch (this) {
    MeetingEvidenceType.handwrittenNotes => 'Handwritten notes',
    MeetingEvidenceType.signInSheet => 'Sign-in sheet',
    MeetingEvidenceType.briefingPhoto => 'Briefing photo',
    MeetingEvidenceType.document => 'Document',
    MeetingEvidenceType.other => 'Other',
  };

  /// Parses a stored value, returning null when [id] is unrecognised.
  ///
  /// Never falls back to a default: an unknown value must not be coerced
  /// into any one type.
  static MeetingEvidenceType? tryFromId(String? id) {
    if (id == null) return null;
    for (final type in MeetingEvidenceType.values) {
      if (type.id == id) return type;
    }
    return null;
  }
}
