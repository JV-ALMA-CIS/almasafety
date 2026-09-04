import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import '../../../core/errors/app_exception.dart';
import 'organization_admin_service.dart';

/// Client for the worker-site assignment callables in
/// `functions/src/site_assignment_callable.ts`.
///
/// Assigning or removing a worker's site access writes the `siteIds` field
/// on `users/{uid}`, which `firestore.rules` denies to every client — there
/// is therefore deliberately no Firestore repository method for it, only
/// this class invoking server-side functions that verify the caller is a
/// System Administrator or an Organization Administrator of the worker's
/// own organization.
///
/// Resolves [FirebaseFunctions.instance] lazily, mirroring
/// [OrganizationAdminService], so it can be constructed before
/// `Firebase.initializeApp()` has run — e.g. in widget tests.
class SiteAssignmentService {
  SiteAssignmentService({FirebaseFunctions? functions}) : _injected = functions;

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

  /// Grants [uid] access to [siteId] within [organizationId]. The server
  /// rejects the call unless [uid] already belongs to [organizationId] and
  /// [siteId] already belongs to [organizationId].
  Future<void> assignWorkerToSite({
    required String uid,
    required String organizationId,
    required String siteId,
  }) => _call<Object?>('assignWorkerToSite', {
    'uid': uid,
    'organizationId': organizationId,
    'siteId': siteId,
  });

  /// Withdraws [uid]'s access to [siteId] within [organizationId].
  ///
  /// This does not cascade to remove any activity assignments the worker
  /// holds at that site — see the callable's doc comment for why that
  /// cascade is deliberately not implemented.
  Future<void> removeWorkerFromSite({
    required String uid,
    required String organizationId,
    required String siteId,
  }) => _call<Object?>('removeWorkerFromSite', {
    'uid': uid,
    'organizationId': organizationId,
    'siteId': siteId,
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
