import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import '../../../core/errors/app_exception.dart';
import '../../organizations/data/organization_admin_service.dart';
import '../../organizations/domain/organization_record_status.dart';

/// Client for the safety meeting point management callables in
/// `functions/src/safety_meeting_point_callable.ts`.
///
/// Creating and editing a meeting point writes fields `firestore.rules`
/// denies to every client — there is therefore deliberately no Firestore
/// repository method for it, only this class invoking server-side functions
/// that verify the caller is a System Administrator or an Organization
/// Administrator of the item's own organization.
///
/// Resolves [FirebaseFunctions.instance] lazily, mirroring
/// [SafetyLearningAdminService], so it can be constructed before
/// `Firebase.initializeApp()` has run — e.g. in widget tests.
class SafetyMeetingPointAdminService {
  SafetyMeetingPointAdminService({FirebaseFunctions? functions})
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

  /// Creates a safety meeting point within [organizationId]. Returns the new
  /// document id.
  Future<String> createSafetyMeetingPoint({
    required String organizationId,
    required String title,
    required String category,
    String? description,
    List<String> applicableActivities = const [],
    List<String> applicableRisks = const [],
    OrganizationRecordStatus status = OrganizationRecordStatus.active,
  }) async {
    final result =
        await _call<Map<Object?, Object?>>('createSafetyMeetingPoint', {
          'organizationId': organizationId,
          'title': title,
          'category': category,
          'description': ?description,
          'applicableActivities': applicableActivities,
          'applicableRisks': applicableRisks,
          'status': status.id,
        });
    return result['id'] as String? ?? '';
  }

  /// Updates a safety meeting point's editable fields. `organizationId`
  /// cannot be changed — a meeting point may not be moved between
  /// organizations.
  Future<void> updateSafetyMeetingPoint(
    String organizationId,
    String id, {
    String? title,
    String? category,
    String? description,
    List<String>? applicableActivities,
    List<String>? applicableRisks,
    OrganizationRecordStatus? status,
  }) => _call<Object?>('updateSafetyMeetingPoint', {
    'organizationId': organizationId,
    'id': id,
    'title': ?title,
    'category': ?category,
    'description': ?description,
    'applicableActivities': ?applicableActivities,
    'applicableRisks': ?applicableRisks,
    if (status != null) 'status': status.id,
  });

  /// Activates a safety meeting point.
  Future<void> activateSafetyMeetingPoint(String organizationId, String id) =>
      _call<Object?>('activateSafetyMeetingPoint', {
        'organizationId': organizationId,
        'id': id,
      });

  /// Deactivates a safety meeting point.
  Future<void> deactivateSafetyMeetingPoint(String organizationId, String id) =>
      _call<Object?>('deactivateSafetyMeetingPoint', {
        'organizationId': organizationId,
        'id': id,
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
