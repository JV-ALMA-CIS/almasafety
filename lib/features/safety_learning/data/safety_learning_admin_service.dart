import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/services/callable_errors.dart';
import '../../organizations/data/organization_admin_service.dart';
import '../../organizations/domain/organization_record_status.dart';
import '../domain/knowledge_check_admin_question.dart';
import '../domain/knowledge_check_question.dart';
import '../domain/safety_learning_type.dart';

/// Client for the safety learning content-management callables in
/// `functions/src/safety_learning_callable.ts`.
///
/// Creating and editing a safety learning item writes fields
/// `firestore.rules` denies to every client — there is therefore
/// deliberately no Firestore repository method for it, only this class
/// invoking server-side functions that verify the caller is a System
/// Administrator or an Organization Administrator of the item's own
/// organization.
///
/// Resolves [FirebaseFunctions.instance] lazily, mirroring
/// [ActivityAdminService], so it can be constructed before
/// `Firebase.initializeApp()` has run — e.g. in widget tests.
class SafetyLearningAdminService {
  SafetyLearningAdminService({FirebaseFunctions? functions})
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

  /// Creates a safety learning item within [organizationId]. Returns the
  /// new document id.
  ///
  /// [minimumWatchSeconds] only applies when [type] is
  /// [SafetyLearningType.video] — see `SafetyLearning.minimumWatchSeconds`'s
  /// doc comment for exactly what it does and does not verify.
  Future<String> createSafetyLearning({
    required String organizationId,
    required String title,
    required SafetyLearningType type,
    required String contentReference,
    String? description,
    OrganizationRecordStatus status = OrganizationRecordStatus.active,
    int? minimumWatchSeconds,
    int? passingScorePercent,
  }) async {
    final result = await _call<Map<Object?, Object?>>('createSafetyLearning', {
      'organizationId': organizationId,
      'title': title,
      'type': type.id,
      'contentReference': contentReference,
      'description': ?description,
      'status': status.id,
      'minimumWatchSeconds': ?minimumWatchSeconds,
      'passingScorePercent': ?passingScorePercent,
    });
    return result['id'] as String? ?? '';
  }

  /// Updates a safety learning item's editable fields. `organizationId`
  /// cannot be changed — an item may not be moved between organizations.
  /// Pass `minimumWatchSeconds: 0` (or omit it) to leave the threshold at
  /// "no minimum"; pass a positive value to set one; there is deliberately
  /// no way to distinguish "not supplied" from "clear it" at this layer
  /// since 0 already means "no minimum" — mirroring how a truly absent value
  /// behaves. Same convention for [passingScorePercent].
  Future<void> updateSafetyLearning(
    String organizationId,
    String id, {
    String? title,
    SafetyLearningType? type,
    String? contentReference,
    String? description,
    OrganizationRecordStatus? status,
    int? minimumWatchSeconds,
    int? passingScorePercent,
  }) => _call<Object?>('updateSafetyLearning', {
    'organizationId': organizationId,
    'id': id,
    'title': ?title,
    if (type != null) 'type': type.id,
    'contentReference': ?contentReference,
    'description': ?description,
    if (status != null) 'status': status.id,
    'minimumWatchSeconds': ?minimumWatchSeconds,
    'passingScorePercent': ?passingScorePercent,
  });

  /// Lists every knowledge-check question for [learningId], WITH
  /// [KnowledgeCheckAdminQuestion.correctOptionId] — see that class's doc
  /// comment for why this is the one path that ever exposes a correct
  /// answer, and only to an admin.
  Future<List<KnowledgeCheckAdminQuestion>> listKnowledgeCheckQuestions({
    required String organizationId,
    required String learningId,
  }) async {
    final result = await _call<Map<Object?, Object?>>(
      'listKnowledgeCheckQuestions',
      {'organizationId': organizationId, 'learningId': learningId},
    );
    final questions = result['questions'];
    if (questions is! List) return const [];
    return questions
        .whereType<Map>()
        .map((q) => KnowledgeCheckAdminQuestion.fromMap(q.cast()))
        .toList(growable: false);
  }

  /// Adds a multiple-choice knowledge-check question to [learningId].
  /// [options] must have 2-6 entries with unique ids; [correctOptionId] must
  /// match one of them.
  Future<String> addKnowledgeCheckQuestion({
    required String organizationId,
    required String learningId,
    required String prompt,
    required List<KnowledgeCheckOption> options,
    required String correctOptionId,
    required int order,
  }) async {
    final result =
        await _call<Map<Object?, Object?>>('addKnowledgeCheckQuestion', {
          'organizationId': organizationId,
          'learningId': learningId,
          'prompt': prompt,
          'options': options.map((o) => o.toMap()).toList(),
          'correctOptionId': correctOptionId,
          'order': order,
        });
    return result['id'] as String? ?? '';
  }

  /// Updates an existing knowledge-check question. Every field is required
  /// (unlike [updateSafetyLearning]'s partial-update style) — see
  /// `updateKnowledgeCheckQuestion`'s own doc comment
  /// (`functions/src/safety_learning_callable.ts`) for why.
  Future<void> updateKnowledgeCheckQuestion({
    required String organizationId,
    required String learningId,
    required String questionId,
    required String prompt,
    required List<KnowledgeCheckOption> options,
    required String correctOptionId,
    required int order,
  }) => _call<Object?>('updateKnowledgeCheckQuestion', {
    'organizationId': organizationId,
    'learningId': learningId,
    'questionId': questionId,
    'prompt': prompt,
    'options': options.map((o) => o.toMap()).toList(),
    'correctOptionId': correctOptionId,
    'order': order,
  });

  /// Removes a knowledge-check question outright — see
  /// `removeKnowledgeCheckQuestion`'s own doc comment
  /// (`functions/src/safety_learning_callable.ts`) for why this is a real
  /// delete, unlike every other record type in this codebase.
  Future<void> removeKnowledgeCheckQuestion({
    required String organizationId,
    required String learningId,
    required String questionId,
  }) => _call<Object?>('removeKnowledgeCheckQuestion', {
    'organizationId': organizationId,
    'learningId': learningId,
    'questionId': questionId,
  });

  /// How many quiz questions each video in [organizationId] has, by
  /// learning id — for video authors (Admin, or a Site Manager of the
  /// organization). Counts only; never the questions or answers.
  ///
  /// A video missing from the result was not counted — it is never treated
  /// as zero. A malformed response throws rather than returning a partial
  /// map; a server without this function throws
  /// [ServerUpdateRequiredException].
  Future<Map<String, int>> getVideoQuizSummary({
    required String organizationId,
  }) async {
    final result = await _call<Object?>('getVideoQuizSummary', {
      'organizationId': organizationId,
    }, feature: 'Quiz counts');
    final raw = result is Map ? result['questionCounts'] : null;
    if (raw is! Map) {
      throw const DataException(
        'The server sent quiz counts in an unexpected format.',
      );
    }
    final counts = <String, int>{};
    for (final entry in raw.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String || value is! num || value < 0) {
        throw const DataException(
          'The server sent quiz counts in an unexpected format.',
        );
      }
      counts[key] = value.toInt();
    }
    return counts;
  }

  /// Permanently deletes [id] — only when nothing depends on it: no learner
  /// has a record for it and no Safety Requirement (active or not) lists
  /// it. Its quiz questions and its own uploaded file go with it. The
  /// server refuses otherwise, with the reason (deactivate it instead), and
  /// refuses when it cannot complete the check. See `deleteSafetyLearning`
  /// (`functions/src/learning_delete_callable.ts`).
  ///
  /// Returns whether the uploaded file (if any) was removed as well.
  Future<bool> deleteSafetyLearning({
    required String organizationId,
    required String id,
  }) async {
    final result = await _call<Map<Object?, Object?>>('deleteSafetyLearning', {
      'organizationId': organizationId,
      'id': id,
    }, feature: 'Deleting videos');
    return result['fileDeleted'] != false;
  }

  /// Moves an upload from the caller's own staging folder
  /// (`learning_uploads/{uid}/...`) into the organization's library folder,
  /// after a server-side author check, and returns the download URL to save
  /// as the item's content reference. No client may write the library
  /// folder directly — see `publishLearningUpload`
  /// (`functions/src/learning_upload_callable.ts`).
  Future<String> publishLearningUpload({
    required String organizationId,
    required String uploadPath,
  }) async {
    final result = await _call<Map<Object?, Object?>>('publishLearningUpload', {
      'organizationId': organizationId,
      'uploadPath': uploadPath,
    }, feature: 'Uploading files');
    final url = result['contentReference'];
    if (url is! String || url.isEmpty) {
      throw const DataException('The upload could not be published.');
    }
    return url;
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
