/// The lifecycle status of one `Hazard`. Mirrors `CorrectiveActionStatus`'s
/// style.
///
/// `reported -> acknowledged -> correctiveActionCreated -> closed`.
/// [closed] is TERMINAL, reachable either directly from [reported]/
/// [acknowledged] (no remediation needed) or by completing the linked
/// corrective action once [correctiveActionCreated] — see
/// `functions/src/hazard_callable.ts`'s header note.
enum HazardStatus {
  reported,
  acknowledged,
  correctiveActionCreated,
  closed;

  /// The value stored in Firestore.
  String get id => name;

  String get label => switch (this) {
    HazardStatus.reported => 'Reported',
    HazardStatus.acknowledged => 'Acknowledged',
    HazardStatus.correctiveActionCreated => 'Corrective Action Created',
    HazardStatus.closed => 'Closed',
  };

  bool get isTerminal => this == HazardStatus.closed;

  /// Parses a stored value, returning null when [id] is unrecognised.
  ///
  /// Never falls back to a default: an unknown value must not be coerced
  /// into any one status.
  static HazardStatus? tryFromId(String? id) {
    if (id == null) return null;
    for (final status in HazardStatus.values) {
      if (status.id == id) return status;
    }
    return null;
  }
}
