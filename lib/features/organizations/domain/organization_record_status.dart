/// The lifecycle status shared by organizations, projects and sites.
///
/// A single status vocabulary across all three record types keeps the
/// System Administrator UI consistent and avoids three near-identical enums
/// that could drift. [active] is the only status new records can start in;
/// [inactive] marks a record wound down without deleting it, preserving
/// historical references from operational data built on later stages.
enum OrganizationRecordStatus {
  active,
  inactive;

  /// The value stored in Firestore.
  String get id => name;

  String get label => switch (this) {
    OrganizationRecordStatus.active => 'Active',
    OrganizationRecordStatus.inactive => 'Inactive',
  };

  /// Parses a stored value, returning null when [id] is unrecognised.
  ///
  /// Never falls back to a default: an unknown value must not be coerced
  /// into [active].
  static OrganizationRecordStatus? tryFromId(String? id) {
    if (id == null) return null;
    for (final status in OrganizationRecordStatus.values) {
      if (status.id == id) return status;
    }
    return null;
  }
}
