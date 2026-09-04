import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import '../../../core/errors/app_exception.dart';
import '../../organizations/data/organization_admin_service.dart';
import '../../organizations/domain/organization_record_status.dart';
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
  Future<String> createSafetyLearning({
    required String organizationId,
    required String title,
    required SafetyLearningType type,
    required String contentReference,
    String? description,
    OrganizationRecordStatus status = OrganizationRecordStatus.active,
  }) async {
    final result = await _call<Map<Object?, Object?>>(
      'createSafetyLearning',
      {
        'organizationId': organizationId,
        'title': title,
        'type': type.id,
        'contentReference': contentReference,
        'description': ?description,
        'status': status.id,
      },
    );
    return result['id'] as String? ?? '';
  }

  /// Updates a safety learning item's editable fields. `organizationId`
  /// cannot be changed — an item may not be moved between organizations.
  Future<void> updateSafetyLearning(
    String organizationId,
    String id, {
    String? title,
    SafetyLearningType? type,
    String? contentReference,
    String? description,
    OrganizationRecordStatus? status,
  }) => _call<Object?>('updateSafetyLearning', {
    'organizationId': organizationId,
    'id': id,
    'title': ?title,
    if (type != null) 'type': type.id,
    'contentReference': ?contentReference,
    'description': ?description,
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
