/// The kind of content a [SafetyLearning] item is. Mirrors
/// `OrganizationRecordStatus`'s `.id`/`.label`/`tryFromId` pattern exactly.
///
/// Kept as a closed, simple vocabulary — no rich content-block model, no file
/// upload pipeline. [contentReference] on [SafetyLearning] carries the actual
/// content as a single opaque string (a URL or document reference); this enum
/// only tells the UI how to present that reference.
enum SafetyLearningType {
  video,
  course,
  visualGuide,
  document,
  knowledgeCheck;

  /// The value stored in Firestore.
  String get id => name;

  String get label => switch (this) {
    SafetyLearningType.video => 'Video',
    SafetyLearningType.course => 'Course',
    SafetyLearningType.visualGuide => 'Visual Guide',
    SafetyLearningType.document => 'Document',
    SafetyLearningType.knowledgeCheck => 'Knowledge Check',
  };

  /// Parses a stored value, returning null when [id] is unrecognised.
  ///
  /// Never falls back to a default: an unknown value must not be coerced
  /// into any particular type.
  static SafetyLearningType? tryFromId(String? id) {
    if (id == null) return null;
    for (final type in SafetyLearningType.values) {
      if (type.id == id) return type;
    }
    return null;
  }
}
