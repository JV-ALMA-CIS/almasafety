import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/callable_errors.dart';
import '../../organizations/data/organization_admin_service.dart';
import '../domain/complete_learning_result.dart';
import '../domain/knowledge_check_question.dart';
import '../domain/knowledge_check_result.dart';
import '../domain/lesson_quiz.dart';
import '../domain/submitted_answer.dart';
import '../domain/todays_safety_readiness.dart';
import '../domain/worker_learning_record.dart';
import '../domain/worker_learning_status.dart';

/// Client for the worker-progress callables in
/// `functions/src/worker_learning_callable.ts`.
///
/// **This is the first codebase feature where an ordinary Worker writes
/// something themselves**, and it deliberately still goes through Cloud
/// Functions callables rather than direct client Firestore writes gated by
/// rules-language self-checks — see [WorkerLearningRecord]'s doc comment.
/// None of these three callables accept a `workerUid` argument: every one
/// derives the acting worker from `request.auth.uid` server-side, so there
/// is no code path by which a worker could pass someone else's uid.
///
/// A worker can start/complete learning that is already required of them —
/// that is completing something an administrator's [SafetyRequirement]
/// already assigned, NOT self-assigning required training. Creating a
/// [SafetyRequirement] or editing `requiredLearningIds` is admin-only
/// content management (see [SafetyRequirementAdminService]) and is a wholly
/// separate authorization path from this class.
///
/// Resolves [FirebaseFunctions.instance] lazily, mirroring
/// [ActivityAssignmentService], so it can be constructed before
/// `Firebase.initializeApp()` has run — e.g. in widget tests.
class WorkerLearningService {
  WorkerLearningService({FirebaseFunctions? functions}) : _injected = functions;

  final FirebaseFunctions? _injected;

  FirebaseFunctions? get _functions {
    if (_injected != null) return _injected;
    if (Firebase.apps.isEmpty) return null;
    return FirebaseFunctions.instance;
  }

  FirebaseFunctions _require() {
    final functions = _functions;
    if (functions == null) {
      throw const DataException(
        'Cannot reach the safety service right now. Please try again.',
      );
    }
    return functions;
  }

  /// Resolves the caller's own required learning within [organizationId]
  /// and lazily materializes an `assigned` [WorkerLearningRecord] for each
  /// required item that has no record yet. Returns nothing directly — the
  /// caller should re-read via [WorkerLearningRepository.watchMine] after
  /// calling this, which is why this class returns `void`: the merged view
  /// lives in Firestore afterward, not in the callable's response.
  Future<void> getMyRequiredLearning({required String organizationId}) =>
      _call<Object?>('getMyRequiredLearning', {
        'organizationId': organizationId,
      });

  /// Starts the caller's own learning record for [learningId] within
  /// [organizationId] — `assigned` -> `inProgress`. The server re-derives
  /// whether [learningId] is actually required of the caller; nothing here
  /// is trusted from the client.
  Future<void> startLearning({
    required String organizationId,
    required String learningId,
  }) => _call<Object?>('startLearning', {
    'organizationId': organizationId,
    'learningId': learningId,
  });

  /// Completes the caller's own learning record for [learningId] within
  /// [organizationId] — `assigned`/`inProgress` -> `completed`, PROVIDED any
  /// configured gates (video minimum-watch-time, knowledge check) pass —
  /// see `completeLearning`'s doc comment
  /// (`functions/src/worker_learning_callable.ts`).
  ///
  /// [selectedAnswers] is the worker's knowledge-check submission — only
  /// meaningful, and only required, when [learningId] actually has
  /// configured questions; omit it for any other item. There is deliberately
  /// no `passed`/`score` parameter here at all: the server computes and
  /// returns the authoritative result in [CompleteLearningResult], and a
  /// failed check is a normal return value, not a thrown exception — see
  /// that class's own doc comment.
  Future<CompleteLearningResult> completeLearning({
    required String organizationId,
    required String learningId,
    List<SubmittedAnswer>? selectedAnswers,
  }) async {
    final result = await _call<Map<Object?, Object?>>('completeLearning', {
      'organizationId': organizationId,
      'learningId': learningId,
      if (selectedAnswers != null)
        'selectedAnswers': selectedAnswers.map((a) => a.toMap()).toList(),
    });
    return CompleteLearningResult.fromMap(result);
  }

  /// The worker-safe view of [learningId]'s knowledge-check questions —
  /// never includes the correct answer; see [KnowledgeCheckQuestion]'s doc
  /// comment. Returns an empty list when none are configured, which is not
  /// an error: an item with zero questions simply has no knowledge-check
  /// gate.
  Future<List<KnowledgeCheckQuestion>> getKnowledgeCheckQuestions({
    required String organizationId,
    required String learningId,
  }) async {
    final result = await _call<Map<Object?, Object?>>(
      'getKnowledgeCheckQuestions',
      {'organizationId': organizationId, 'learningId': learningId},
    );
    final questions = result['questions'];
    if (questions is! List) return const [];
    return questions
        .whereType<Map>()
        .map((q) => KnowledgeCheckQuestion.fromMap(q.cast()))
        .toList(growable: false);
  }

  /// This lesson's quiz for the caller — the questions (never the answers),
  /// whether the lesson is required of them and whether its quiz is part of
  /// that requirement. Available for any active lesson, so an optional
  /// video's quiz can be practised (see [practiceKnowledgeCheck]).
  ///
  /// A server from before that change refuses a lesson that is not
  /// required of the caller with [_outdatedQuizRefusal]; that is reported
  /// as [ServerUpdateRequiredException] — the learner is allowed, the
  /// server is just old.
  Future<LessonQuiz> getLessonQuiz({
    required String organizationId,
    required String learningId,
  }) async {
    try {
      final result = await _call<Map<Object?, Object?>>(
        'getKnowledgeCheckQuestions',
        {'organizationId': organizationId, 'learningId': learningId},
      );
      return LessonQuiz.fromMap(result);
    } on DataException catch (e) {
      throw quizLoadError(e);
    }
  }

  /// [error] from loading a quiz, or [ServerUpdateRequiredException] when it
  /// is an older server's refusal of a lesson not required of the caller.
  static AppException quizLoadError(DataException error) {
    final cause = error.cause;
    if (cause is FirebaseFunctionsException &&
        cause.code == 'failed-precondition' &&
        cause.message == _outdatedQuizRefusal) {
      return ServerUpdateRequiredException(
        "This quiz can't open yet because the server needs the latest "
        "update. This isn't a problem with your account — ask your "
        'administrator to deploy the update.',
        cause: cause,
      );
    }
    return error;
  }

  /// What `getKnowledgeCheckQuestions` said, before general learning
  /// existed, for a lesson not required of the caller. The current server
  /// never sends it from that function.
  static const _outdatedQuizRefusal =
      'That learning item is not currently required of you.';

  /// Grades a practice attempt at an OPTIONAL lesson's quiz. Nothing is
  /// recorded — optional learning is never tracked; a required lesson's
  /// quiz goes through [completeLearning].
  Future<KnowledgeCheckResult> practiceKnowledgeCheck({
    required String organizationId,
    required String learningId,
    required List<SubmittedAnswer> selectedAnswers,
  }) async {
    final result = await _call<Map<Object?, Object?>>(
      'practiceKnowledgeCheck',
      {
        'organizationId': organizationId,
        'learningId': learningId,
        'selectedAnswers': [for (final a in selectedAnswers) a.toMap()],
      },
      feature: 'Practice quizzes',
    );
    final raw = result['knowledgeCheckResult'];
    if (raw is! Map) {
      throw const DataException('The quiz result could not be read.');
    }
    return KnowledgeCheckResult.fromMap(raw.cast());
  }

  /// A reviewer's (Admin/Site Manager/Foreman) view of the learning-progress
  /// records for [workerUids] within [organizationId] —
  /// [SafetyComplianceRepository.buildSiteCompliance]'s completion-status
  /// source.
  ///
  /// **Why this goes through a callable, not a direct Firestore read.**
  /// `firestore.rules` deliberately does not grant a Foreman read access to
  /// `worker_learning_records` (a Site Manager/Admin have that access
  /// directly, since [WorkerLearningRepository.watchForOrganization] is
  /// still correct for them) — that collection's own rule comment says a
  /// Foreman's visibility into their crew's training "is provided elsewhere
  /// via the callables, not this rule." A Foreman calling this returns only
  /// the subset of [workerUids] who actually share one of the Foreman's own
  /// assigned sites, re-checked fresh server-side — never trusted from
  /// [workerUids] itself; see `getCrewLearningRecords`'s own doc comment
  /// (`functions/src/worker_learning_callable.ts`).
  Future<List<WorkerLearningRecord>> getCrewLearningRecords({
    required String organizationId,
    required List<String> workerUids,
  }) async {
    if (workerUids.isEmpty) return const [];
    final result = await _call<Map<Object?, Object?>>(
      'getCrewLearningRecords',
      {'organizationId': organizationId, 'workerUids': workerUids},
    );
    final records = result['records'];
    if (records is! List) return const [];
    // Parsed inline, not via WorkerLearningRecord.fromMap: this callable's
    // JSON response carries completedAt as an ISO 8601 string (there is no
    // Firestore Timestamp type over the wire), unlike fromMap's Firestore
    // document shape, and this class only ever needs status/completedAt —
    // buildSiteCompliance never reads assignedAt/startedAt/
    // knowledgeCheckResult from these rows.
    return records
        .whereType<Map>()
        .map((raw) {
          final map = raw.cast<String, dynamic>();
          final status = WorkerLearningStatus.tryFromId(
            map['status'] as String?,
          );
          final completedAtRaw = map['completedAt'] as String?;
          return WorkerLearningRecord(
            id: map['id'] as String? ?? '',
            workerUid: map['workerUid'] as String? ?? '',
            organizationId: map['organizationId'] as String? ?? organizationId,
            learningId: map['learningId'] as String? ?? '',
            status: status ?? WorkerLearningStatus.assigned,
            completedAt: completedAtRaw == null
                ? null
                : DateTime.tryParse(completedAtRaw),
            // Video progress only — quiz results are never sent here.
            contentCompletedFlag: map['contentCompleted'] == true,
          );
        })
        .toList(growable: false);
  }

  /// The caller's own focused learning view for today — see
  /// `getMyTodaysSafetyReadiness`'s doc comment
  /// (`functions/src/worker_learning_callable.ts`). Read-only, and like
  /// every method here it takes no worker uid: the server derives it from
  /// the caller's own auth.
  Future<TodaysSafetyReadiness> getMyTodaysSafetyReadiness({
    required String organizationId,
  }) async {
    final result = await _call<Map<Object?, Object?>>(
      'getMyTodaysSafetyReadiness',
      {'organizationId': organizationId},
    );
    return TodaysSafetyReadiness.fromMap(result);
  }

  /// [feature] names a recently added server function, so a server without
  /// it is reported as needing an update — see [missingServerFunction].
  Future<T> _call<T>(
    String name,
    Map<String, Object?>? data, {
    String? feature,
  }) async {
    try {
      final callable = _require().httpsCallable(name);
      final result = await callable.call<T>(data);
      return result.data;
    } on FirebaseFunctionsException catch (e) {
      if (feature != null) {
        final outdated = missingServerFunction(e, feature);
        if (outdated != null) throw outdated;
      }
      throw OrganizationAdminService.mapCallableError(e);
    }
  }
}
