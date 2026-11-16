import 'knowledge_check_result.dart';
import 'worker_learning_status.dart';

/// The parsed response from the `completeLearning` callable
/// (`functions/src/worker_learning_callable.ts`).
///
/// [status] reflects what the record's status actually is AFTER this call —
/// `completed` on success, or unchanged (`assigned`/`inProgress`) when a
/// knowledge check was attempted but not passed. A failed knowledge check is
/// an EXPECTED outcome, not a thrown error — see
/// [KnowledgeCheckResult.passed] and `completeLearning`'s own doc comment.
class CompleteLearningResult {
  const CompleteLearningResult({
    required this.status,
    this.knowledgeCheckResult,
    this.contentCompleted = false,
    this.quizOutstanding = false,
  });

  final WorkerLearningStatus status;
  final KnowledgeCheckResult? knowledgeCheckResult;

  /// The content step (video watched) is recorded.
  final bool contentCompleted;

  /// A mandatory quiz still has to be passed before the item is complete.
  final bool quizOutstanding;

  factory CompleteLearningResult.fromMap(Map<Object?, Object?> data) {
    final status =
        WorkerLearningStatus.tryFromId(data['status'] as String?) ??
        WorkerLearningStatus.inProgress;
    final rawResult = data['knowledgeCheckResult'];
    return CompleteLearningResult(
      status: status,
      contentCompleted:
          data['contentCompleted'] == true ||
          status == WorkerLearningStatus.completed,
      quizOutstanding: data['quizOutstanding'] == true,
      knowledgeCheckResult: rawResult is Map
          ? KnowledgeCheckResult.fromMap(rawResult.cast())
          : null,
    );
  }
}
