import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import '../../../core/errors/app_exception.dart';
import '../../organizations/data/organization_admin_service.dart';

/// Client for the worker-activity assignment callables in
/// `functions/src/activity_assignment_callable.ts`.
///
/// Assigning or removing a worker from an activity writes a subcollection
/// document `firestore.rules` denies to every client — there is therefore
/// deliberately no Firestore repository method for it, only this class
/// invoking server-side functions. The server independently re-validates
/// that the worker already has site access for the activity's site before
/// assigning — see that callable file's doc comment for the full validation
/// chain; nothing sent from here is trusted on its own.
///
/// Resolves [FirebaseFunctions.instance] lazily, mirroring
/// [OrganizationAdminService], so it can be constructed before
/// `Firebase.initializeApp()` has run — e.g. in widget tests.
class ActivityAssignmentService {
  ActivityAssignmentService({FirebaseFunctions? functions})
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

  /// Assigns [uid] to [activityId] within [organizationId].
  ///
  /// The server rejects the call unless [uid] already belongs to
  /// [organizationId] and already has the activity's site in their
  /// `siteIds` — see the callable's doc comment for the complete chain.
  Future<void> assignWorkerToActivity({
    required String uid,
    required String organizationId,
    required String activityId,
  }) => _call<Object?>('assignWorkerToActivity', {
    'uid': uid,
    'organizationId': organizationId,
    'activityId': activityId,
  });

  /// Removes [uid]'s assignment to [activityId] within [organizationId].
  Future<void> removeWorkerFromActivity({
    required String uid,
    required String organizationId,
    required String activityId,
  }) => _call<Object?>('removeWorkerFromActivity', {
    'uid': uid,
    'organizationId': organizationId,
    'activityId': activityId,
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
