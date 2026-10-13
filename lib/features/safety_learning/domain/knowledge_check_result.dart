/// The AUTHORITATIVE, server-computed outcome of a worker's knowledge-check
/// submission, stored on a [WorkerLearningRecord] whenever the associated
/// [SafetyLearning] has at least one configured knowledge-check question —
/// regardless of [SafetyLearningType]; see [SafetyLearning]'s own doc
/// comment for why a knowledge check is not confined to
/// [SafetyLearningType.knowledgeCheck] items.
///
/// **Server-computed, never client-submitted.** `completeLearning`
/// (`functions/src/worker_learning_callable.ts`) grades the worker's
/// `selectedAnswers` against the authoritative answer key itself and writes
/// this shape verbatim — the client never sends `passed`/`score` and the
/// server never reads such fields even if one were present in a request.
/// [totalQuestions] is absent on a record completed before this phase (the
/// old self-attested `{passed: true}` shape) — see [fromMap]'s
/// backward-compatibility handling.
class KnowledgeCheckResult {
  const KnowledgeCheckResult({
    required this.passed,
    this.score,
    this.totalQuestions,
  });

  final bool passed;

  /// The number of questions answered correctly. Null only for a record
  /// written before this phase (the old self-attested shape carried no
  /// score at all in most cases) — never null for a freshly graded result.
  final int? score;

  /// The total number of questions this result was graded against. Null for
  /// a pre-existing record written before this field existed.
  final int? totalQuestions;

  factory KnowledgeCheckResult.fromMap(Map<String, dynamic> data) {
    return KnowledgeCheckResult(
      passed: data['passed'] as bool? ?? false,
      score: (data['score'] as num?)?.toInt(),
      totalQuestions: (data['totalQuestions'] as num?)?.toInt(),
    );
  }

  Map<String, Object?> toMap() => {
    'passed': passed,
    if (score != null) 'score': score,
    if (totalQuestions != null) 'totalQuestions': totalQuestions,
  };
}
