import '../domain/site_emergency_info.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import '../../../core/errors/app_exception.dart';
import '../domain/organization_record_status.dart';

/// Client for the organization/project/site management callables in
/// `functions/src/organization_callable.ts`.
///
/// Creating and editing an organization, project or site writes fields
/// `firestore.rules` denies to every client, exactly like account review —
/// there is therefore deliberately no Firestore repository method for it,
/// only this class invoking server-side functions that verify the caller is
/// a System Administrator themselves.
///
/// Nothing this class sends is trusted by the server: `createSite` in
/// particular re-verifies that the named project actually belongs to the
/// named organization before writing, so a modified client cannot create a
/// site whose organization and project disagree by supplying a mismatched
/// pair.
///
/// Resolves [FirebaseFunctions.instance] lazily, mirroring
/// [AccountApprovalService], so it can be constructed before
/// `Firebase.initializeApp()` has run — e.g. in widget tests.
class OrganizationAdminService {
  OrganizationAdminService({FirebaseFunctions? functions})
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

  /// Creates an organization. Returns the new document id.
  Future<String> createOrganization({
    required String name,
    required String code,
    OrganizationRecordStatus status = OrganizationRecordStatus.active,
  }) async {
    final result = await _call<Map<Object?, Object?>>('createOrganization', {
      'name': name,
      'code': code,
      'status': status.id,
    });
    return result['id'] as String? ?? '';
  }

  /// Updates an organization's editable fields. Only non-null parameters
  /// are changed.
  Future<void> updateOrganization(
    String id, {
    String? name,
    String? code,
    OrganizationRecordStatus? status,
  }) => _call<Object?>('updateOrganization', {
    'id': id,
    'name': ?name,
    'code': ?code,
    if (status != null) 'status': status.id,
  });

  /// Creates a project within [organizationId], which must already exist.
  /// Returns the new document id.
  Future<String> createProject({
    required String organizationId,
    required String name,
    required String code,
    String? description,
    OrganizationRecordStatus status = OrganizationRecordStatus.active,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final result = await _call<Map<Object?, Object?>>('createProject', {
      'organizationId': organizationId,
      'name': name,
      'code': code,
      'description': ?description,
      'status': status.id,
      if (startDate != null) 'startDate': startDate.toIso8601String(),
      if (endDate != null) 'endDate': endDate.toIso8601String(),
    });
    return result['id'] as String? ?? '';
  }

  /// Updates a project's editable fields. `organizationId` cannot be
  /// changed — a project may not be moved between organizations.
  Future<void> updateProject(
    String organizationId,
    String id, {
    String? name,
    String? code,
    String? description,
    OrganizationRecordStatus? status,
    DateTime? startDate,
    DateTime? endDate,
  }) => _call<Object?>('updateProject', {
    'organizationId': organizationId,
    'id': id,
    'name': ?name,
    'code': ?code,
    'description': ?description,
    if (status != null) 'status': status.id,
    if (startDate != null) 'startDate': startDate.toIso8601String(),
    if (endDate != null) 'endDate': endDate.toIso8601String(),
  });

  /// Creates a site within [organizationId] and [projectId], both of which
  /// must already exist, with [projectId]'s own `organizationId` matching
  /// [organizationId] — the server refuses a mismatched pair. Returns the
  /// new document id.
  Future<String> createSite({
    required String organizationId,
    required String projectId,
    required String name,
    required String code,
    String? location,
    String? description,
    OrganizationRecordStatus status = OrganizationRecordStatus.active,
  }) async {
    final result = await _call<Map<Object?, Object?>>('createSite', {
      'organizationId': organizationId,
      'projectId': projectId,
      'name': name,
      'code': code,
      'location': ?location,
      'description': ?description,
      'status': status.id,
    });
    return result['id'] as String? ?? '';
  }

  /// Updates a site's editable fields. `organizationId` and `projectId`
  /// cannot be changed — a site may not be moved between organizations or
  /// projects.
  Future<void> updateSite(
    String organizationId,
    String id, {
    String? name,
    String? code,
    String? location,
    String? description,
    OrganizationRecordStatus? status,
  }) => _call<Object?>('updateSite', {
    'organizationId': organizationId,
    'id': id,
    'name': ?name,
    'code': ?code,
    'location': ?location,
    'description': ?description,
    if (status != null) 'status': status.id,
  });

  /// Saves a site's emergency contacts (Site Manager/Admin).
  Future<void> updateSiteEmergencyInfo(
    String organizationId,
    String siteId,
    SiteEmergencyInfo emergency,
  ) => _call<Object?>('updateSiteEmergencyInfo', {
    'organizationId': organizationId,
    'siteId': siteId,
    'emergency': emergency.toJson(),
  });

  Future<T> _call<T>(String name, [Map<String, Object?>? data]) async {
    try {
      final callable = _require().httpsCallable(name);
      final result = await callable.call<T>(data);
      return result.data;
    } on FirebaseFunctionsException catch (e) {
      throw mapCallableError(e);
    }
  }

  /// Translates a callable failure into the app exception hierarchy.
  ///
  /// The server returns one opaque `permission-denied` for every
  /// authorization failure, and this preserves that — mirrors
  /// `AccountApprovalService.mapCallableError` exactly.
  static AppException mapCallableError(FirebaseFunctionsException e) {
    switch (e.code) {
      case 'permission-denied':
      case 'unauthenticated':
        return PermissionDeniedException(
          'You do not have permission to do that.',
          cause: e,
        );
      case 'unavailable':
      case 'deadline-exceeded':
        return NetworkException(
          'Network error. Check your connection and try again.',
          cause: e,
        );
      case 'not-found':
        return DataException('That record no longer exists.', cause: e);
      case 'failed-precondition':
        return DataException(
          e.message ?? 'That request could not be completed.',
          cause: e,
        );
      case 'invalid-argument':
        return DataException(
          e.message ?? 'That request was invalid.',
          cause: e,
        );
      default:
        return DataException(
          'Something went wrong. Please try again.',
          cause: e,
        );
    }
  }
}
