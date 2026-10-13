/// What kind of report a hazard is, matching the fixed set
/// `functions/src/hazard_callable.ts`'s `requireKind` accepts.
///
/// Orthogonal to [HazardCategory]: a near-miss at height is still
/// `workingAtHeight`. A later incident record (something that actually
/// happened) is deliberately NOT a value here — it needs its own fields.
enum HazardKind {
  /// Something COULD happen — an unsafe condition or act.
  hazard,

  /// Something NEARLY happened — an event that could have hurt someone or
  /// damaged something, but didn't.
  nearMiss;

  /// The value stored in Firestore.
  String get id => name;

  String get label => switch (this) {
    HazardKind.hazard => 'Hazard',
    HazardKind.nearMiss => 'Near-miss',
  };

  /// Parses a stored value. Unlike [HazardCategory.tryFromId], an ABSENT
  /// value means [hazard] — every report filed before near-misses existed
  /// has no `kind` field. An unrecognised value still returns null.
  static HazardKind? tryFromId(String? id) {
    if (id == null) return HazardKind.hazard;
    for (final kind in HazardKind.values) {
      if (kind.id == id) return kind;
    }
    return null;
  }
}
