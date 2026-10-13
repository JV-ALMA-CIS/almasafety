/// A worker's answer to one Pre-Start question. Mirrors `ANSWERS` in
/// `functions/src/pre_start_check_callable.ts`.
enum PreStartAnswer {
  /// "Yes" — the statement is true.
  yes,

  /// "No", but the worker fixed it on the spot (the note says how).
  fixed,

  /// "No", and the worker could not fix it (the note says what is wrong).
  cannotFix;

  String get id => name;

  String get label => switch (this) {
    PreStartAnswer.yes => 'Yes',
    PreStartAnswer.fixed => 'No — I fixed it',
    PreStartAnswer.cannotFix => "No — I can't fix it",
  };

  /// Every answer except "yes" must carry a note.
  bool get needsNote => this != PreStartAnswer.yes;

  static PreStartAnswer? tryFromId(Object? id) {
    for (final answer in PreStartAnswer.values) {
      if (answer.id == id) return answer;
    }
    return null;
  }
}
