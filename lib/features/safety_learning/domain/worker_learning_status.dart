/// The lifecycle status of one worker's progress through one
/// [SafetyLearning] item. Mirrors `OrganizationRecordStatus`'s style.
///
/// A worker's record starts at [assigned] the moment a
/// [SafetyRequirement] first names the learning item as required for their
/// organization (materialized lazily — see `getMyRequiredLearning` in
/// `functions/src/worker_learning_callable.ts`), moves to [inProgress] when
/// the worker calls `startLearning`, and to [completed] when the worker
/// calls `completeLearning`. Every transition is server-authoritative — see
/// [WorkerLearningRecord]'s doc comment.
enum WorkerLearningStatus {
  assigned,
  inProgress,
  completed;

  /// The value stored in Firestore.
  String get id => name;

  String get label => switch (this) {
    WorkerLearningStatus.assigned => 'Assigned',
    WorkerLearningStatus.inProgress => 'In Progress',
    WorkerLearningStatus.completed => 'Completed',
  };

  /// Parses a stored value, returning null when [id] is unrecognised.
  ///
  /// Never falls back to a default: an unknown value must not be coerced
  /// into [assigned].
  static WorkerLearningStatus? tryFromId(String? id) {
    if (id == null) return null;
    for (final status in WorkerLearningStatus.values) {
      if (status.id == id) return status;
    }
    return null;
  }
}
