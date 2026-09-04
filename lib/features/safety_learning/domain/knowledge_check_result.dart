/// The outcome of a worker's knowledge-check submission, stored on a
/// [WorkerLearningRecord] only when the associated [SafetyLearning.type] is
/// [SafetyLearningType.knowledgeCheck].
///
/// A small typed value object rather than an untyped `Map<String, dynamic>`
/// — matches this codebase's typed-everything style. There is deliberately
/// no "correct answer key" concept: grading/knowledge-check content
/// authoring is out of scope for this stage (see
/// `functions/src/worker_learning_callable.ts`'s `completeLearning` doc
/// comment). The server validates only the *shape* of this result
/// (`passed` is a bool, `score` if present is a number) and stores it as
/// submitted — it does not grade it.
class KnowledgeCheckResult {
  const KnowledgeCheckResult({required this.passed, this.score});

  final bool passed;
  final int? score;

  factory KnowledgeCheckResult.fromMap(Map<String, dynamic> data) {
    return KnowledgeCheckResult(
      passed: data['passed'] as bool? ?? false,
      score: (data['score'] as num?)?.toInt(),
    );
  }

  Map<String, Object?> toMap() => {
    'passed': passed,
    if (score != null) 'score': score,
  };
}
