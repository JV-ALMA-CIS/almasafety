/// A hazard's category, matching the fixed set
/// `functions/src/hazard_callable.ts`'s `requireCategory` accepts —
/// PROJECT_CONTEXT.md §24.
enum HazardCategory {
  workingAtHeight,
  electrical,
  equipment,
  ppe,
  housekeeping,
  environment,
  chemical,
  fire,
  other;

  /// The value stored in Firestore.
  String get id => name;

  String get label => switch (this) {
    HazardCategory.workingAtHeight => 'Working at Height',
    HazardCategory.electrical => 'Electrical',
    HazardCategory.equipment => 'Equipment',
    HazardCategory.ppe => 'PPE',
    HazardCategory.housekeeping => 'Housekeeping',
    HazardCategory.environment => 'Environment',
    HazardCategory.chemical => 'Chemical',
    HazardCategory.fire => 'Fire',
    HazardCategory.other => 'Other',
  };

  /// Parses a stored value, returning null when [id] is unrecognised.
  ///
  /// Never falls back to a default: an unknown value must not be coerced
  /// into any one category.
  static HazardCategory? tryFromId(String? id) {
    if (id == null) return null;
    for (final category in HazardCategory.values) {
      if (category.id == id) return category;
    }
    return null;
  }
}
