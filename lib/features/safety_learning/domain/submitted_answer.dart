/// One worker's selected option for one knowledge-check question — the
/// ONLY knowledge-check input `completeLearning`
/// (`functions/src/worker_learning_callable.ts`) ever accepts from a
/// client. There is deliberately no `passed`/`score`/`percent` field
/// anywhere in this shape: grading happens entirely server-side against the
/// authoritative answer key, never from a client-submitted result.
class SubmittedAnswer {
  const SubmittedAnswer({required this.questionId, required this.optionId});

  final String questionId;
  final String optionId;

  Map<String, Object?> toMap() => {
    'questionId': questionId,
    'optionId': optionId,
  };
}
