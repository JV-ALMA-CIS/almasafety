/// One selectable option on a [KnowledgeCheckQuestion].
class KnowledgeCheckOption {
  const KnowledgeCheckOption({required this.id, required this.text});

  final String id;
  final String text;

  factory KnowledgeCheckOption.fromMap(Map<String, dynamic> data) {
    return KnowledgeCheckOption(
      id: data['id'] as String? ?? '',
      text: data['text'] as String? ?? '',
    );
  }

  Map<String, Object?> toMap() => {'id': id, 'text': text};
}

/// The WORKER-SAFE view of one knowledge-check question, returned by the
/// `getKnowledgeCheckQuestions` callable
/// (`functions/src/worker_learning_callable.ts`).
///
/// **Deliberately carries no correct-answer field at all** — not merely one
/// left unpopulated. The server never includes `correctOptionId` in this
/// response; grading happens entirely server-side in `completeLearning`
/// against the authoritative question document
/// (`organizations/{orgId}/safety_learning/{id}/knowledge_check_questions/{qId}`),
/// which `firestore.rules` denies every client read of outright. See
/// `SafetyLearning.passingScorePercent`'s doc comment for the gate this
/// enables.
class KnowledgeCheckQuestion {
  const KnowledgeCheckQuestion({
    required this.id,
    required this.prompt,
    required this.options,
    required this.order,
  });

  final String id;
  final String prompt;
  final List<KnowledgeCheckOption> options;
  final int order;

  factory KnowledgeCheckQuestion.fromMap(Map<String, dynamic> data) {
    final rawOptions = data['options'];
    return KnowledgeCheckQuestion(
      id: data['id'] as String? ?? '',
      prompt: data['prompt'] as String? ?? '',
      options: rawOptions is List
          ? rawOptions
                .whereType<Map>()
                .map((o) => KnowledgeCheckOption.fromMap(o.cast()))
                .toList(growable: false)
          : const [],
      order: (data['order'] as num?)?.toInt() ?? 0,
    );
  }
}
