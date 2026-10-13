import 'knowledge_check_question.dart';

/// The ADMIN-FACING view of one knowledge-check question — includes
/// [correctOptionId], unlike [KnowledgeCheckQuestion] (the worker-safe
/// view). Returned only by `listKnowledgeCheckQuestions`
/// (`functions/src/safety_learning_callable.ts`), `admin`-only, and used
/// only by the authoring UI — see that callable's own doc comment for why
/// this is the one deliberate, narrow path that ever returns a correct
/// answer.
class KnowledgeCheckAdminQuestion {
  const KnowledgeCheckAdminQuestion({
    required this.id,
    required this.prompt,
    required this.options,
    required this.correctOptionId,
    required this.order,
  });

  final String id;
  final String prompt;
  final List<KnowledgeCheckOption> options;
  final String correctOptionId;
  final int order;

  factory KnowledgeCheckAdminQuestion.fromMap(Map<String, dynamic> data) {
    final rawOptions = data['options'];
    return KnowledgeCheckAdminQuestion(
      id: data['id'] as String? ?? '',
      prompt: data['prompt'] as String? ?? '',
      options: rawOptions is List
          ? rawOptions
                .whereType<Map>()
                .map((o) => KnowledgeCheckOption.fromMap(o.cast()))
                .toList(growable: false)
          : const [],
      correctOptionId: data['correctOptionId'] as String? ?? '',
      order: (data['order'] as num?)?.toInt() ?? 0,
    );
  }
}
