/// The result of a Daily Pre-Start Check — and of a crew's Daily Safety
/// Meeting, which the Foreman records with the same three values.
///
/// Mirrors `PRE_START_OUTCOMES` in `functions/src/pre_start_check_callable.ts`.
/// The server always decides a worker's outcome from their answers; this
/// enum only names what it decided.
enum PreStartOutcome {
  /// Every answer was "yes" — safe to start.
  go,

  /// A problem was found and fixed on the spot — work started.
  goCorrected,

  /// A problem could not be fixed — do not start until it is dealt with.
  stop;

  /// The value stored in Firestore and sent to the callables.
  String get id => name;

  String get label => switch (this) {
    PreStartOutcome.go => 'GO',
    PreStartOutcome.goCorrected => 'GO corrected',
    PreStartOutcome.stop => 'STOP',
  };

  /// A plain-language line for a worker or Foreman.
  String get description => switch (this) {
    PreStartOutcome.go => 'Safe to start work.',
    PreStartOutcome.goCorrected => 'A problem was found and fixed.',
    PreStartOutcome.stop => 'Do not start until the problem is dealt with.',
  };

  /// Parses a stored value, returning null when [id] is unrecognised.
  static PreStartOutcome? tryFromId(Object? id) {
    for (final outcome in PreStartOutcome.values) {
      if (outcome.id == id) return outcome;
    }
    return null;
  }
}
