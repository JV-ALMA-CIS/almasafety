import 'pre_start_answer.dart';
import 'pre_start_outcome.dart';

/// One question on today's Pre-Start Check, as `getMyPreStartCheck` returns
/// it. [kind] is `standard` (the five every worker answers) or
/// `requirement` (one per safety requirement that applies to the worker's
/// work today); [risk] is that requirement's risk level, if any.
class PreStartQuestion {
  const PreStartQuestion({
    required this.id,
    required this.prompt,
    required this.kind,
    this.risk,
  });

  final String id;
  final String prompt;
  final String kind;
  final String? risk;

  bool get isHighRisk => risk == 'high';

  static PreStartQuestion? fromMap(Map<Object?, Object?> map) {
    final id = map['id'];
    final prompt = map['prompt'];
    if (id is! String || prompt is! String) return null;
    final kind = map['kind'];
    final risk = map['risk'];
    return PreStartQuestion(
      id: id,
      prompt: prompt,
      kind: kind is String ? kind : 'standard',
      risk: risk is String ? risk : null,
    );
  }
}

/// One answered question — what a worker submitted, or one of the "no"
/// answers a Foreman sees on the crew card.
class PreStartAnsweredQuestion {
  const PreStartAnsweredQuestion({
    required this.prompt,
    required this.answer,
    this.note,
  });

  final String prompt;
  final PreStartAnswer answer;
  final String? note;

  static PreStartAnsweredQuestion? fromMap(Map<Object?, Object?> map) {
    final answer = PreStartAnswer.tryFromId(map['answer']);
    if (answer == null) return null;
    final prompt = map['prompt'];
    final note = map['note'];
    return PreStartAnsweredQuestion(
      prompt: prompt is String ? prompt : '',
      answer: answer,
      note: note is String ? note : null,
    );
  }
}

List<PreStartAnsweredQuestion> _answersFrom(Object? raw) => [
  if (raw is List)
    for (final entry in raw.whereType<Map<Object?, Object?>>())
      ?PreStartAnsweredQuestion.fromMap(entry),
];

/// A worker's submitted check for today.
class PreStartSubmission {
  const PreStartSubmission({required this.outcome, required this.answers});

  final PreStartOutcome outcome;
  final List<PreStartAnsweredQuestion> answers;

  /// The answers other than "yes".
  List<PreStartAnsweredQuestion> get issues => [
    for (final answer in answers)
      if (answer.answer != PreStartAnswer.yes) answer,
  ];

  static PreStartSubmission? fromMap(Map<Object?, Object?> map) {
    final outcome = PreStartOutcome.tryFromId(map['outcome']);
    if (outcome == null) return null;
    return PreStartSubmission(
      outcome: outcome,
      answers: _answersFrom(map['answers']),
    );
  }
}

/// The signed-in worker's check for today: either the [questions] still to
/// answer, or the [submission] already made (a worker checks once a day).
class MyPreStartCheck {
  const MyPreStartCheck({
    required this.date,
    required this.siteName,
    required this.questions,
    this.submission,
  });

  final String date;
  final String siteName;
  final List<PreStartQuestion> questions;
  final PreStartSubmission? submission;

  bool get isDone => submission != null;

  factory MyPreStartCheck.fromMap(Map<Object?, Object?> map) {
    final date = map['date'];
    final site = map['site'];
    final siteName = site is Map ? site['name'] : null;
    final questions = map['questions'];
    final submission = map['submission'];
    return MyPreStartCheck(
      date: date is String ? date : '',
      siteName: siteName is String ? siteName : '',
      questions: [
        if (questions is List)
          for (final entry in questions.whereType<Map<Object?, Object?>>())
            ?PreStartQuestion.fromMap(entry),
      ],
      submission: submission is Map<Object?, Object?>
          ? PreStartSubmission.fromMap(submission)
          : null,
    );
  }
}

/// One crew member's result today, as a Foreman sees it. [outcome] is null
/// when the worker has not done their check yet; [issues] holds only their
/// "no" answers.
class CrewPreStartRow {
  const CrewPreStartRow({
    required this.workerId,
    required this.workerName,
    required this.outcome,
    required this.issues,
  });

  final String workerId;
  final String workerName;
  final PreStartOutcome? outcome;
  final List<PreStartAnsweredQuestion> issues;

  static CrewPreStartRow? fromMap(Map<Object?, Object?> map) {
    final workerId = map['workerId'];
    if (workerId is! String) return null;
    final workerName = map['workerName'];
    return CrewPreStartRow(
      workerId: workerId,
      workerName: workerName is String ? workerName : '',
      outcome: PreStartOutcome.tryFromId(map['outcome']),
      issues: _answersFrom(map['issues']),
    );
  }
}
