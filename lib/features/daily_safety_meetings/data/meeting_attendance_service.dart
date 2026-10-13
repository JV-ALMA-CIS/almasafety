import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import '../../../core/errors/app_exception.dart';
import '../../organizations/data/organization_admin_service.dart';
import '../domain/crew_readiness.dart';

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
  ///
  /// [briefedInPerson] marks a worker present even though today's lessons
  /// are not complete, recording that the Foreman briefed them face to
  /// face; the server ignores it when nothing is outstanding.
  Future<void> recordMeetingAttendance({
    required String organizationId,
    required String meetingId,
    required String workerId,
    required String status,
    bool briefedInPerson = false,
  }) => _call<Object?>('recordMeetingAttendance', {
    'organizationId': organizationId,
    'meetingId': meetingId,
    'workerId': workerId,
    'status': status,
    if (briefedInPerson) 'briefedInPerson': true,
  });

  /// A read-only preview of which workers assigned to [meetingId]'s own
  /// activities have outstanding required safety learning — see
  /// `getMeetingAttendeeLearningStatus`'s doc comment
  /// (`functions/src/daily_safety_meeting_callable.ts`) for why this is a
  /// dedicated, narrow callable rather than a direct `worker_learning_records`
  /// read: `firestore.rules` denies `foreman` read access to that collection
  /// outright, by design, and this callable is the deliberate, audited
  /// exception path. Never blocks or gates anything — informational only.
  ///
  /// Returns one entry per worker assigned to one of this meeting's own
  /// activities (excluding the calling foreman), each with the TITLES of
  /// their outstanding (not-yet-completed) required learning — an empty list
  /// means "checked, nothing outstanding," distinct from that worker simply
  /// not appearing (which never happens for an assigned worker; the map is
  /// always complete for the current attendee roster).
  Future<Map<String, List<String>>> getMeetingAttendeeLearningStatus({
    required String organizationId,
    required String meetingId,
  }) async {
    final result = await _call<Map<Object?, Object?>>(
      'getMeetingAttendeeLearningStatus',
      {'organizationId': organizationId, 'meetingId': meetingId},
    );
    final workers = result['workers'];
    if (workers is! List) return const {};
    return {
      for (final entry in workers.whereType<Map<Object?, Object?>>())
        if (entry['workerId'] is String)
          entry['workerId']! as String: [
            for (final title in (entry['outstanding'] as List? ?? const []))
              if (title is String) title,
          ],
    };
  }

  /// PRE-MEETING crew readiness for one of the caller's own authorized
  /// sites — see `getSiteCrewReadiness`'s doc comment
  /// (`functions/src/daily_safety_meeting_callable.ts`). Resolved from the
  /// site's active activities; once today's meeting is started, use
  /// [getMeetingAttendeeLearningStatus] instead. Unlike that callable,
  /// every rostered worker is always returned, so ready/need-attention
  /// counts are complete.
  Future<CrewReadiness> getSiteCrewReadiness({
    required String organizationId,
    required String siteId,
  }) async {
    final result = await _call<Map<Object?, Object?>>('getSiteCrewReadiness', {
      'organizationId': organizationId,
      'siteId': siteId,
    });
    final activities = result['activities'];
    return CrewReadiness(
      outstandingByWorker: _outstandingByWorker(result['workers']),
      activityNames: [
        if (activities is List)
          for (final activity in activities.whereType<Map>())
            if (activity['name'] is String) activity['name'] as String,
      ],
    );
  }

  static Map<String, List<String>> _outstandingByWorker(Object? workers) {
    if (workers is! List) return const {};
    return {
      for (final entry in workers.whereType<Map<Object?, Object?>>())
        if (entry['workerId'] is String)
          entry['workerId']! as String: [
            for (final title in (entry['outstanding'] as List? ?? const []))
              if (title is String) title,
          ],
    };
  }

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
