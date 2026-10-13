import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import '../../../core/errors/app_exception.dart';
import '../../organizations/data/organization_admin_service.dart';
import '../domain/pre_start_answer.dart';
import '../domain/pre_start_check.dart';
import '../domain/pre_start_outcome.dart';

/// A worker's answer to one question, as submitted.
typedef PreStartResponse = ({PreStartAnswer answer, String? note});

/// Client for the Daily Pre-Start Check callables in
/// `functions/src/pre_start_check_callable.ts`.
///
/// Like every worker-facing write in this app, a check goes through a
/// callable, never a direct Firestore write: the server re-derives today's
/// questions and computes the outcome, and no callable accepts a worker uid
/// — a worker can only ever submit their own check.
///
/// Resolves [FirebaseFunctions.instance] lazily, mirroring
/// [WorkerLearningService], so it can be constructed before
/// `Firebase.initializeApp()` has run — e.g. in widget tests.
class PreStartCheckService {
  PreStartCheckService({FirebaseFunctions? functions}) : _injected = functions;

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

  /// Today's questions for the signed-in worker, or the check they already
  /// submitted today.
  Future<MyPreStartCheck> getMyPreStartCheck({
    required String organizationId,
  }) async {
    final result = await _call<Map<Object?, Object?>>('getMyPreStartCheck', {
      'organizationId': organizationId,
    });
    return MyPreStartCheck.fromMap(result);
  }

  /// Submits the signed-in worker's [answers] — one per question id in
  /// [MyPreStartCheck.questions] — and returns the outcome the server
  /// decided.
  Future<PreStartOutcome> submitPreStartCheck({
    required String organizationId,
    required Map<String, PreStartResponse> answers,
  }) async {
    final result = await _call<Map<Object?, Object?>>('submitPreStartCheck', {
      'organizationId': organizationId,
      'answers': [
        for (final entry in answers.entries)
          {
            'questionId': entry.key,
            'answer': entry.value.answer.id,
            'note': entry.value.note,
          },
      ],
    });
    final outcome = PreStartOutcome.tryFromId(result['outcome']);
    if (outcome == null) {
      throw const DataException('Unexpected response from the safety service.');
    }
    return outcome;
  }

  /// Today's result for every crew member at [siteId].
  Future<List<CrewPreStartRow>> getSiteCrewPreStartChecks({
    required String organizationId,
    required String siteId,
  }) async {
    final result = await _call<Map<Object?, Object?>>(
      'getSiteCrewPreStartChecks',
      {'organizationId': organizationId, 'siteId': siteId},
    );
    final workers = result['workers'];
    return [
      if (workers is List)
        for (final entry in workers.whereType<Map<Object?, Object?>>())
          ?CrewPreStartRow.fromMap(entry),
    ];
  }

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
