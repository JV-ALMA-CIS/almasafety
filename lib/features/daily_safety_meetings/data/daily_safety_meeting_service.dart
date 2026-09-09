import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import '../../../core/errors/app_exception.dart';
import '../../organizations/data/organization_admin_service.dart';

/// Client for the foreman-facing meeting callables in
/// `functions/src/daily_safety_meeting_callable.ts`.
///
/// **This platform does not conduct or record the physical meeting.** Every
/// method here writes only structured facts — which activities and meeting
/// points a meeting covers, plain-text concerns, and completion — never
/// audio, transcription or translation. None of these callables accept a
/// `foremanId` argument: every one derives the acting foreman from
/// `request.auth.uid` server-side, mirroring [WorkerLearningService]'s
/// "no `workerUid` argument" discipline exactly.
///
/// Resolves [FirebaseFunctions.instance] lazily, mirroring
/// [SafetyMeetingPointAdminService], so it can be constructed before
/// `Firebase.initializeApp()` has run — e.g. in widget tests.
class DailySafetyMeetingService {
  DailySafetyMeetingService({FirebaseFunctions? functions})
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

  /// Starts today's meeting for [siteId] within [organizationId]/
  /// [projectId]. The server re-validates the caller is a `foreman` with
  /// [siteId] in their own `siteIds`, and that the site belongs to the given
  /// organization/project — nothing here is trusted from the client alone.
  /// Returns the new meeting's id.
  Future<String> createDailySafetyMeeting({
    required String organizationId,
    required String projectId,
    required String siteId,
    List<String> activityIds = const [],
    List<String> meetingPointIds = const [],
  }) async {
    final result = await _call<Map<Object?, Object?>>(
      'createDailySafetyMeeting',
      {
        'organizationId': organizationId,
        'projectId': projectId,
        'siteId': siteId,
        'activityIds': activityIds,
        'meetingPointIds': meetingPointIds,
      },
    );
    return result['id'] as String? ?? '';
  }

  /// Updates an in-progress meeting's activities, meeting points and/or
  /// concerns. Only the meeting's own foreman may call this — the server
  /// re-checks `meeting.foremanId == request.auth.uid`.
  Future<void> updateDailySafetyMeeting(
    String organizationId,
    String id, {
    List<String>? activityIds,
    List<String>? meetingPointIds,
    List<String>? concerns,
  }) => _call<Object?>('updateDailySafetyMeeting', {
    'organizationId': organizationId,
    'id': id,
    'activityIds': ?activityIds,
    'meetingPointIds': ?meetingPointIds,
    'concerns': ?concerns,
  });

  /// Completes the meeting: the server requires at least one activity and
  /// one meeting point already recorded, then sets `status` to `completed`.
  Future<void> completeDailySafetyMeeting(
    String organizationId,
    String id,
  ) => _call<Object?>('completeDailySafetyMeeting', {
    'organizationId': organizationId,
    'id': id,
  });

  /// Sets (creates or overwrites) the discussion note for one meeting point
  /// on an in-progress meeting — what was actually explained/discussed
  /// about it, kept deliberately separate from Concerns (see
  /// [MeetingPointNote]'s doc comment). Refuses if [meetingPointId] is not
  /// currently on the meeting's own `meetingPointIds`, or once the meeting
  /// is completed.
  Future<void> setMeetingPointNote({
    required String organizationId,
    required String meetingId,
    required String meetingPointId,
    required String note,
  }) => _call<Object?>('setMeetingPointNote', {
    'organizationId': organizationId,
    'meetingId': meetingId,
    'meetingPointId': meetingPointId,
    'note': note,
  });

  /// Removes a meeting point's discussion note from an in-progress meeting.
  /// Succeeds even if the point itself was already removed from
  /// `meetingPointIds` — this is how the client cleans up a note when the
  /// point is removed from the meeting entirely, see
  /// `functions/src/daily_safety_meeting_callable.ts`'s doc comment on
  /// `removeMeetingPointNote`.
  Future<void> removeMeetingPointNote({
    required String organizationId,
    required String meetingId,
    required String meetingPointId,
  }) => _call<Object?>('removeMeetingPointNote', {
    'organizationId': organizationId,
    'meetingId': meetingId,
    'meetingPointId': meetingPointId,
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
