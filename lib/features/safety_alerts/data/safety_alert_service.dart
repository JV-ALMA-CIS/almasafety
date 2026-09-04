import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import '../../../core/errors/app_exception.dart';
import '../../organizations/data/organization_admin_service.dart';

/// Client for the `createSafetyAlert`/`acknowledgeSafetyAlert`/
/// `resolveSafetyAlert` callables in `functions/src/safety_alert_callable.ts`.
///
/// Mirrors [CorrectiveActionService]: resolves [FirebaseFunctions.instance]
/// lazily so it can be constructed before `Firebase.initializeApp()` has
/// run — e.g. in widget tests. None of these callables accept a
/// `createdBy`/`acknowledgedBy`/`resolvedBy` argument: the server derives
/// the acting user from `request.auth.uid`, mirroring every other write
/// surface in this codebase.
class SafetyAlertService {
  SafetyAlertService({FirebaseFunctions? functions}) : _injected = functions;

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

  /// Creates a safety alert for [siteId] within [organizationId]/
  /// [projectId]. The server re-validates the caller holds an authorized
  /// reviewer role and re-fetches the site to confirm it belongs to the
  /// given organization/project — nothing here is trusted from the client
  /// alone. Returns the new alert's id.
  Future<String> createSafetyAlert({
    required String organizationId,
    required String projectId,
    required String siteId,
    required String title,
    required String description,
    required String severity,
    required String category,
  }) async {
    final result = await _call<Map<Object?, Object?>>('createSafetyAlert', {
      'organizationId': organizationId,
      'projectId': projectId,
      'siteId': siteId,
      'title': title,
      'description': description,
      'severity': severity,
      'category': category,
    });
    return result['id'] as String? ?? '';
  }

  /// Acknowledges an active alert, moving it to `acknowledged`.
  Future<void> acknowledgeSafetyAlert({
    required String organizationId,
    required String alertId,
  }) => _call<Object?>('acknowledgeSafetyAlert', {
    'organizationId': organizationId,
    'alertId': alertId,
  });

  /// Resolves an alert, moving it to `resolved` — a terminal state.
  Future<void> resolveSafetyAlert({
    required String organizationId,
    required String alertId,
  }) => _call<Object?>('resolveSafetyAlert', {
    'organizationId': organizationId,
    'alertId': alertId,
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
