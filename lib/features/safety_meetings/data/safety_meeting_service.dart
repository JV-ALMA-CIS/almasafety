import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import '../../../core/errors/app_exception.dart';
import '../../organizations/data/organization_admin_service.dart';
import '../domain/safety_meeting.dart';

/// Client for `functions/src/safety_meeting_callable.ts`.
class SafetyMeetingService {
  SafetyMeetingService({FirebaseFunctions? functions}) : _injected = functions;

  final FirebaseFunctions? _injected;

  FirebaseFunctions _require() {
    final injected = _injected;
    if (injected != null) return injected;
    if (Firebase.apps.isEmpty) {
      throw const DataException(
        'Cannot reach the safety service right now. Please try again.',
      );
    }
    return FirebaseFunctions.instance;
  }

  /// Records a meeting that has taken place; returns its id. [siteId] is
  /// null only for a monthly supervisory meeting covering every site.
  Future<String> record({
    required String organizationId,
    required SafetyMeetingKind kind,
    required String? siteId,
    required DateTime date,
    required List<String> topics,
    required List<String> attendeeUids,
    List<String> otherAttendees = const [],
    List<String> concerns = const [],
    String? notes,
  }) async {
    try {
      final result = await _require()
          .httpsCallable('recordSafetyMeeting')
          .call<Map<Object?, Object?>>({
            'organizationId': organizationId,
            'kind': kind.id,
            'siteId': siteId,
            'date': meetingDateId(date),
            'topics': topics,
            'attendeeUids': attendeeUids,
            'otherAttendees': otherAttendees,
            'concerns': concerns,
            'notes': ?notes,
          });
      return result.data['id'] as String? ?? '';
    } on FirebaseFunctionsException catch (e) {
      throw OrganizationAdminService.mapCallableError(e);
    }
  }
}
