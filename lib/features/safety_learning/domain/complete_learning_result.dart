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
  });

  final WorkerLearningStatus status;
  final KnowledgeCheckResult? knowledgeCheckResult;

  factory CompleteLearningResult.fromMap(Map<Object?, Object?> data) {
    final status =
        WorkerLearningStatus.tryFromId(data['status'] as String?) ??
        WorkerLearningStatus.inProgress;
    final rawResult = data['knowledgeCheckResult'];
    return CompleteLearningResult(
      status: status,
      knowledgeCheckResult: rawResult is Map
          ? KnowledgeCheckResult.fromMap(rawResult.cast())
          : null,
    );
  }
}
