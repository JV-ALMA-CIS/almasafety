import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import '../../../core/errors/app_exception.dart';
import '../../organizations/data/organization_admin_service.dart';

/// Client for the `recordMeetingAttendance` callable in
/// `functions/src/daily_safety_meeting_callable.ts`.
///
/// Mirrors [DailySafetyMeetingService]: resolves [FirebaseFunctions.instance]
/// lazily so it can be constructed before `Firebase.initializeApp()` has
/// run — e.g. in widget tests. This callable does not accept a `recordedBy`
/// argument: the server derives the acting foreman from `request.auth.uid`,
/// mirroring every other write surface in this feature.
class MeetingAttendanceService {
  MeetingAttendanceService({FirebaseFunctions? functions})
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

  /// Records or updates [workerId]'s attendance status on [meetingId] within
  /// [organizationId]. The server re-validates the caller is the meeting's
  /// own foreman, that [workerId] belongs to the meeting's own site, and
  /// that [workerId] is not the caller themself — nothing here is trusted
  /// from the client alone.
  Future<void> recordMeetingAttendance({
    required String organizationId,
    required String meetingId,
    required String workerId,
    required String status,
  }) => _call<Object?>('recordMeetingAttendance', {
    'organizationId': organizationId,
    'meetingId': meetingId,
    'workerId': workerId,
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
