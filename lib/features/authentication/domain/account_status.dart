/// The authoritative account-state field for a JVA Safety user
/// (PROJECT_CONTEXT.md §19).
///
/// This replaces the earlier `active: bool` flag entirely — there is exactly
/// one notion of account state, and it lives here. A second boolean would
/// invite the two to disagree.
///
/// Lifecycle: REGISTER → [pending] → authorized review → [active], with
/// [rejected] and [suspended] as the terminal/negative outcomes. Only
/// [active] grants access to operational routes and data.
enum AccountStatus {
  /// Self-registered, awaiting review by an authorized organizational user.
  /// No operational access whatsoever.
  pending,

  /// Approved and assigned to an organization. Full app access.
  active,

  /// Previously active, access withdrawn by an administrator. Recoverable.
  suspended,

  /// Reviewed and refused. Terminal.
  rejected;

  /// The value stored in the Firestore `accountStatus` field.
  String get id => name;

  /// Human-readable label for UI surfaces.
  String get label => switch (this) {
    AccountStatus.pending => 'Pending Approval',
    AccountStatus.active => 'Active',
    AccountStatus.suspended => 'Suspended',
    AccountStatus.rejected => 'Rejected',
  };

  /// Whether this status grants access to operational functionality.
  ///
  /// Expressed as a positive allow-list of exactly one value rather than a
  /// "not rejected" style check, so any status added later is denied by
  /// default until it is deliberately allowed.
  bool get grantsAccess => this == AccountStatus.active;

  /// Parses a stored value, returning null when [id] is unrecognised.
  ///
  /// Never falls back to a default: an unknown value must not be coerced
  /// into [active].
  static AccountStatus? tryFromId(String? id) {
    if (id == null) return null;
    for (final status in AccountStatus.values) {
      if (status.id == id) return status;
    }
    return null;
  }

  /// Strict parse used when deserializing a profile. Throws
  /// [ArgumentError] on an unknown value so a malformed document surfaces
  /// as a load failure and denies access.
  static AccountStatus fromId(String? id) {
    final status = tryFromId(id);
    if (status == null) {
      throw ArgumentError.value(id, 'id', 'Unknown ALMASAFETY account status');
    }
    return status;
  }
}
