import 'todays_safety_readiness.dart';
import 'worker_learning_record.dart';
import 'worker_learning_status.dart';

/// The learning ids the learner holds an UNFINISHED record for that are no
/// longer required of them — the requirement was removed or deactivated, or
/// they moved site or activity. Records are never deleted, so these stay in
/// the learner's list, where they open as general learning.
///
/// [readiness] is the server's own answer (`getMyTodaysSafetyReadiness`):
/// every unfinished lesson still required of the learner appears in one of
/// its lists with `canStart` set — the same required set `startLearning`
/// and `completeLearning` enforce. Completed records are history and are
/// never included.
Set<String> noLongerRequiredLearningIds(
  Iterable<WorkerLearningRecord> records,
  TodaysSafetyReadiness readiness,
) {
  final stillRequired = {
    for (final item in [
      ...readiness.beforeMeeting,
      ...readiness.beforeWork,
      ...readiness.additional,
      ...readiness.neededTomorrow,
    ])
      if (item.canStart) item.learningId,
  };
  return {
    for (final record in records)
      if (record.status != WorkerLearningStatus.completed &&
          !stillRequired.contains(record.learningId))
        record.learningId,
  };
}
