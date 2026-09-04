/// A [SafetyRequirement]'s administrator-entered severity label. Mirrors
/// `OrganizationRecordStatus`'s style.
///
/// This is deliberately a plain, minimal three-value vocabulary rather than a
/// free-text field or a rich risk-scoring system: it is administrator-
/// entered (never AI-derived or automatically computed — see this feature's
/// task notes), so it only needs to be simple enough for a human to pick
/// consistently, not expressive enough to model a formal risk matrix.
enum SafetyRequirementRisk {
  low,
  medium,
  high;

  /// The value stored in Firestore.
  String get id => name;

  String get label => switch (this) {
    SafetyRequirementRisk.low => 'Low',
    SafetyRequirementRisk.medium => 'Medium',
    SafetyRequirementRisk.high => 'High',
  };

  /// Parses a stored value, returning null when [id] is unrecognised.
  ///
  /// Never falls back to a default: an unknown value must not be coerced
  /// into any particular risk level.
  static SafetyRequirementRisk? tryFromId(String? id) {
    if (id == null) return null;
    for (final risk in SafetyRequirementRisk.values) {
      if (risk.id == id) return risk;
    }
    return null;
  }
}
