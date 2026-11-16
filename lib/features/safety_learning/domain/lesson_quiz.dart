import 'knowledge_check_question.dart';

/// A lesson's quiz as the learner sees it — `getKnowledgeCheckQuestions`'
/// answer: the questions without their answers, whether the lesson is
/// [required] of this learner, and whether passing the quiz is part of
/// that requirement ([quizRequired]).
///
/// Both flags come from the learner's own Safety Requirements, resolved
/// server-side; a quiz is never mandatory just because it exists.
///
/// An older server sends neither flag ([serverReportsRequirement] false).
/// It only ever served a lesson that WAS required of the caller, and every
/// quiz it served was mandatory, so that is how such an answer reads.
class LessonQuiz {
  const LessonQuiz({
    required this.questions,
    required this.required,
    required this.quizRequired,
    this.serverReportsRequirement = true,
  });

  final List<KnowledgeCheckQuestion> questions;
  final bool required;
  final bool quizRequired;

  /// Whether [required] came from the server rather than being inferred
  /// from an older server's answer.
  final bool serverReportsRequirement;

  bool get hasQuiz => questions.isNotEmpty;

  factory LessonQuiz.fromMap(Map<Object?, Object?> map) {
    final raw = map['questions'];
    final questions = raw is List
        ? raw
              .whereType<Map>()
              .map((q) => KnowledgeCheckQuestion.fromMap(q.cast()))
              .toList(growable: false)
        : const <KnowledgeCheckQuestion>[];
    if (!map.containsKey('required')) {
      return LessonQuiz(
        questions: questions,
        required: true,
        quizRequired: questions.isNotEmpty,
        serverReportsRequirement: false,
      );
    }
    return LessonQuiz(
      questions: questions,
      required: map['required'] == true,
      quizRequired: map['quizRequired'] == true && questions.isNotEmpty,
    );
  }
}
