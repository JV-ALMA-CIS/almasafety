/// The fixed value sets of an `Incident`, matching
/// `functions/src/incident_callable.ts`'s `INCIDENT_TYPES`/
/// `INCIDENT_SEVERITIES` and its lifecycle.
library;

/// What actually happened. A near-miss is NOT one of these — nobody was hurt
/// and nothing was damaged, so it is a hazard report (`HazardKind.nearMiss`);
/// the report form points people there.
enum IncidentType {
  injury,
  propertyDamage,
  environmental,
  dangerousOccurrence,

  /// Anything the list doesn't cover — every site is different; the
  /// description says what happened.
  other;

  /// The value stored in Firestore.
  String get id => name;

  String get label => switch (this) {
    IncidentType.injury => 'Someone was hurt',
    IncidentType.propertyDamage => 'Something was damaged',
    IncidentType.environmental => 'Spill or pollution',
    IncidentType.dangerousOccurrence => 'Dangerous event',
    IncidentType.other => 'Something else',
  };

  /// One line telling people which type to pick, with examples.
  String get hint => switch (this) {
    IncidentType.injury => 'Any injury, even first aid only',
    IncidentType.propertyDamage =>
      'Equipment, vehicle, structure or materials damaged',
    IncidentType.environmental => 'Fuel, oil or chemical spill, dust, waste',
    IncidentType.dangerousOccurrence =>
      'e.g. scaffold collapse, crane failure, fire — even if nobody was hurt',
    IncidentType.other => "Doesn't fit the above — describe it below",
  };

  /// Parses a stored value, returning null when [id] is unrecognised.
  static IncidentType? tryFromId(String? id) {
    for (final value in IncidentType.values) {
      if (value.id == id) return value;
    }
    return null;
  }
}

/// How serious an incident was — classified by a reviewer when the
/// investigation starts, never by the reporter.
enum IncidentSeverity {
  minor,
  moderate,
  serious;

  String get id => name;

  String get label => switch (this) {
    IncidentSeverity.minor => 'Minor',
    IncidentSeverity.moderate => 'Moderate',
    IncidentSeverity.serious => 'Serious',
  };

  /// What each level means, shown when a reviewer classifies one.
  String get guidance => switch (this) {
    IncidentSeverity.minor => 'First aid only, or minor damage',
    IncidentSeverity.moderate => 'Medical treatment, or work stopped',
    IncidentSeverity.serious => 'Lost time, hospital, or major damage',
  };

  static IncidentSeverity? tryFromId(String? id) {
    for (final value in IncidentSeverity.values) {
      if (value.id == id) return value;
    }
    return null;
  }
}

/// `reported -> underInvestigation -> closed`. [closed] is TERMINAL.
enum IncidentStatus {
  reported,
  underInvestigation,
  closed;

  String get id => name;

  String get label => switch (this) {
    IncidentStatus.reported => 'Reported',
    IncidentStatus.underInvestigation => 'Under Investigation',
    IncidentStatus.closed => 'Closed',
  };

  bool get isTerminal => this == IncidentStatus.closed;

  static IncidentStatus? tryFromId(String? id) {
    for (final value in IncidentStatus.values) {
      if (value.id == id) return value;
    }
    return null;
  }
}
