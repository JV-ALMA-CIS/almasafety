import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import '../../../core/errors/app_exception.dart';
import '../../organizations/data/organization_admin_service.dart';
import '../domain/risk_assessment.dart';

/// Client for `functions/src/risk_assessment_callable.ts`.
class RiskAssessmentService {
  RiskAssessmentService({FirebaseFunctions? functions}) : _injected = functions;

  final FirebaseFunctions? _injected;

  FirebaseFunctions _require() {
    final injected = _injected;
    if (injected != null) return injected;
    if (Firebase.apps.isEmpty) {
      throw const DataException(
        'Cannot reach the safety service right now. Please try again.',
      );
    }
    return FirebaseFunctions.instance;
  }

  /// Creates a draft (no [id]; [siteId] required) or edits a draft; returns
  /// its id.
  Future<String> save({
    required String organizationId,
    String? id,
    String? siteId,
    List<String> activityIds = const [],
    required AhaContent content,
  }) async {
    final result = await _call('saveRiskAssessment', {
      'organizationId': organizationId,
      'id': ?id,
      'siteId': ?siteId,
      'activityIds': activityIds,
      'featureOfWork': content.featureOfWork,
      'activity': ?content.activity,
      'contractNo': ?content.contractNo,
      'location': ?content.location,
      'estimatedStartDate': ?content.estimatedStartDate,
      'steps': [for (final step in content.steps) step.toJson()],
      'equipment': content.equipment,
      'inspectionRequirements': content.inspectionRequirements,
      'trainingRequirements': content.trainingRequirements,
    });
    return result['id'] as String? ?? id ?? '';
  }

  /// Accepts a draft (someone other than its preparer).
  Future<void> accept({
    required String organizationId,
    required String id,
    String? corName,
    String? note,
  }) => _call('acceptRiskAssessment', {
    'organizationId': organizationId,
    'id': id,
    'corName': ?corName,
    'note': ?note,
  });

  /// Starts a revision of an accepted AHA; returns the new draft's id.
  Future<String> revise({
    required String organizationId,
    required String id,
  }) async {
    final result = await _call('reviseRiskAssessment', {
      'organizationId': organizationId,
      'id': id,
    });
    return result['id'] as String? ?? '';
  }

  /// Deletes a draft that was never accepted.
  Future<void> discardDraft({
    required String organizationId,
    required String id,
  }) => _call('discardRiskAssessmentDraft', {
    'organizationId': organizationId,
    'id': id,
  });

  Future<Map<Object?, Object?>> _call(
    String name,
    Map<String, Object?> data,
  ) async {
    try {
      final result = await _require()
          .httpsCallable(name)
          .call<Map<Object?, Object?>>(data);
      return result.data;
    } on FirebaseFunctionsException catch (e) {
      throw OrganizationAdminService.mapCallableError(e);
    }
  }
}
