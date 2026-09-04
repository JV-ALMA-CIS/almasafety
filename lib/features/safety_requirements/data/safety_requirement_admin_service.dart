import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import '../../../core/errors/app_exception.dart';
import '../../organizations/data/organization_admin_service.dart';
import '../../organizations/domain/organization_record_status.dart';
import '../domain/safety_requirement_risk.dart';

/// Client for the safety requirement content-management callables in
/// `functions/src/safety_learning_callable.ts`.
///
/// Creating and editing a safety requirement writes fields
/// `firestore.rules` denies to every client — there is therefore
/// deliberately no Firestore repository method for it, only this class
/// invoking server-side functions that verify the caller is a System
/// Administrator or an Organization Administrator of the requirement's own
/// organization. `updateSafetyRequirement`'s `requiredLearningIds` argument
/// is re-validated server-side against real `SafetyLearning` documents in
/// the same organization — nothing sent from here is trusted on its own.
///
/// Resolves [FirebaseFunctions.instance] lazily, mirroring
/// [ActivityAdminService], so it can be constructed before
/// `Firebase.initializeApp()` has run — e.g. in widget tests.
class SafetyRequirementAdminService {
  SafetyRequirementAdminService({FirebaseFunctions? functions})
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

  /// Creates a safety requirement within [organizationId]. Returns the new
  /// document id.
  Future<String> createSafetyRequirement({
    required String organizationId,
    required String name,
    required String category,
    required SafetyRequirementRisk risk,
    String? description,
    List<String> requiredLearningIds = const [],
    OrganizationRecordStatus status = OrganizationRecordStatus.active,
  }) async {
    final result = await _call<Map<Object?, Object?>>(
      'createSafetyRequirement',
      {
        'organizationId': organizationId,
        'name': name,
        'category': category,
        'risk': risk.id,
        'description': ?description,
        'requiredLearningIds': requiredLearningIds,
        'status': status.id,
      },
    );
    return result['id'] as String? ?? '';
  }

  /// Updates a safety requirement's editable fields, including
  /// `requiredLearningIds`. `organizationId` cannot be changed — a
  /// requirement may not be moved between organizations.
  Future<void> updateSafetyRequirement(
    String organizationId,
    String id, {
    String? name,
    String? category,
    SafetyRequirementRisk? risk,
    String? description,
    List<String>? requiredLearningIds,
    OrganizationRecordStatus? status,
  }) => _call<Object?>('updateSafetyRequirement', {
    'organizationId': organizationId,
    'id': id,
    'name': ?name,
    'category': ?category,
    if (risk != null) 'risk': risk.id,
    'description': ?description,
    'requiredLearningIds': ?requiredLearningIds,
    if (status != null) 'status': status.id,
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
