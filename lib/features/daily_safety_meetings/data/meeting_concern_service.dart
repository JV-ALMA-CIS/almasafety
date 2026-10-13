import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import '../../../core/errors/app_exception.dart';
import '../../organizations/data/organization_admin_service.dart';

/// Client for the `addMeetingConcern`/`updateMeetingConcern`/
/// `removeMeetingConcern` callables in
/// `functions/src/daily_safety_meeting_callable.ts`.
///
/// Mirrors [MeetingAttendanceService]: resolves [FirebaseFunctions.instance]
/// lazily so it can be constructed before `Firebase.initializeApp()` has
/// run — e.g. in widget tests. None of these callables accept a
/// `reportedBy` argument: the server derives the acting foreman from
/// `request.auth.uid`, mirroring every other write surface in this feature.
class MeetingConcernService {
  MeetingConcernService({FirebaseFunctions? functions}) : _injected = functions;

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

  /// Adds a new concern to [meetingId] within [organizationId]. The server
  /// re-validates the caller is the meeting's own foreman on an
  /// `inProgress` meeting — nothing here is trusted from the client alone.
  /// Returns the new concern's id.
  Future<String> addMeetingConcern({
    required String organizationId,
    required String meetingId,
    required String description,
    required String category,
  }) async {
    final result = await _call<Map<Object?, Object?>>('addMeetingConcern', {
      'organizationId': organizationId,
      'meetingId': meetingId,
      'description': description,
      'category': category,
    });
    return result['id'] as String? ?? '';
  }

  /// Edits an existing, unsaved-in-the-sense-of-`open` concern's
  /// description and/or category. The server re-checks the same
  /// meeting-own-foreman-and-`inProgress` chain as [addMeetingConcern], plus
  /// that [concernId] actually belongs to [meetingId].
  Future<void> updateMeetingConcern({
    required String organizationId,
    required String meetingId,
    required String concernId,
    String? description,
    String? category,
  }) => _call<Object?>('updateMeetingConcern', {
    'organizationId': organizationId,
    'meetingId': meetingId,
    'concernId': concernId,
    'description': ?description,
    'category': ?category,
  });

  /// Removes a concern from an in-progress meeting before it is completed.
  Future<void> removeMeetingConcern({
    required String organizationId,
    required String meetingId,
    required String concernId,
  }) => _call<Object?>('removeMeetingConcern', {
    'organizationId': organizationId,
    'meetingId': meetingId,
    'concernId': concernId,
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
