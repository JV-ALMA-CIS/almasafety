import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import '../../../core/errors/app_exception.dart';
import '../../organizations/data/organization_admin_service.dart';

/// Client for the `createCorrectiveAction`/`updateCorrectiveActionStatus`
/// callables in `functions/src/corrective_action_callable.ts`.
///
/// Mirrors [MeetingConcernService]: resolves [FirebaseFunctions.instance]
/// lazily so it can be constructed before `Firebase.initializeApp()` has
/// run — e.g. in widget tests. Neither callable accepts an `assignedBy`
/// argument: the server derives the acting foreman from `request.auth.uid`,
/// mirroring every other write surface in this feature.
class CorrectiveActionService {
  CorrectiveActionService({FirebaseFunctions? functions})
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

  /// Creates a corrective action within [organizationId], from EITHER
  /// [meetingId] (optionally naming a specific [concernId]) OR [hazardId] —
  /// exactly one of the two must be given, mirroring
  /// `createCorrectiveAction`'s own "exactly one of meetingId or hazardId"
  /// server-side validation.
  ///
  /// MEETING-ORIGINATED: the server re-validates the caller is the meeting's
  /// own foreman on an `inProgress` meeting, and that [concernId] (when
  /// given) belongs to that meeting.
  ///
  /// HAZARD-ORIGINATED: the server re-validates the caller holds an
  /// authorized reviewer role, and that the hazard is not already closed or
  /// already linked to another corrective action — same path as
  /// `HazardService.linkCorrectiveAction`, which calls the same underlying
  /// implementation server-side.
  ///
  /// In both cases, [assignedTo] must be an active member of this
  /// organization — nothing here is trusted from the client alone. Returns
  /// the new action's id.
  Future<String> createCorrectiveAction({
    required String organizationId,
    required String title,
    required String description,
    required String assignedTo,
    required DateTime dueDate,
    String? meetingId,
    String? concernId,
    String? hazardId,
    bool evidenceRequired = false,
  }) async {
    assert(
      (meetingId == null) != (hazardId == null),
      'Exactly one of meetingId or hazardId must be given.',
    );
    final result = await _call<Map<Object?, Object?>>(
      'createCorrectiveAction',
      {
        'organizationId': organizationId,
        'title': title,
        'description': description,
        'assignedTo': assignedTo,
        'dueDate': dueDate.toIso8601String(),
        'meetingId': ?meetingId,
        'concernId': ?concernId,
        'hazardId': ?hazardId,
        'evidenceRequired': evidenceRequired,
      },
    );
    return result['id'] as String? ?? '';
  }

  /// Transitions [actionId]'s status. The server re-validates the caller
  /// holds an authorized supervisor/manager role (`admin`/`siteManager`)
  /// within [organizationId] — see `requireOrganizationScopedReviewer` in
  /// the callable file.
  Future<void> updateCorrectiveActionStatus({
    required String organizationId,
    required String actionId,
    required String status,
  }) => _call<Object?>('updateCorrectiveActionStatus', {
    'organizationId': organizationId,
    'actionId': actionId,
    'status': status,
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
