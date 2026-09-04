import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import '../../../core/errors/app_exception.dart';
import '../../organizations/data/organization_admin_service.dart';
import '../domain/knowledge_check_result.dart';

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
  WorkerLearningService({FirebaseFunctions? functions})
    : _injected = functions;

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
  Future<void> getMyRequiredLearning({
    required String organizationId,
  }) => _call<Object?>('getMyRequiredLearning', {
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
  /// [organizationId] — `assigned`/`inProgress` -> `completed`.
  /// [knowledgeCheckResult] is required when the learning item's type is
  /// `knowledgeCheck`; the server validates its shape, not its correctness
  /// (see [KnowledgeCheckResult]'s doc comment).
  Future<void> completeLearning({
    required String organizationId,
    required String learningId,
    KnowledgeCheckResult? knowledgeCheckResult,
  }) => _call<Object?>('completeLearning', {
    'organizationId': organizationId,
    'learningId': learningId,
    if (knowledgeCheckResult != null)
      'knowledgeCheckResult': knowledgeCheckResult.toMap(),
  });

  Future<T> _call<T>(String name, [Map<String, Object?>? data]) async {
    try {
      final callable = _require().httpsCallable(name);
      final result = await callable.call<T>(data);
      return result.data;
    } on FirebaseFunctionsException catch (e) {
      throw OrganizationAdminService.mapCallableError(e);
    }
  }
}
