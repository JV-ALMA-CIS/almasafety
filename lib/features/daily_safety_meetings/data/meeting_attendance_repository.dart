import '../../../core/constants/firestore_paths.dart';
import '../../../core/services/firestore_repository.dart';
import '../../../core/services/firestore_service.dart';
import '../domain/meeting_attendance.dart';

/// Reads attendance records for one Daily Safety Meeting from
/// `organizations/{organizationId}/daily_safety_meetings/{meetingId}/attendance`.
///
/// Read-only — see [DailySafetyMeetingRepository]'s doc comment for why
/// creating and editing an attendance record goes through a callable
/// instead ([MeetingAttendanceService]). Scoped to one organization and
/// meeting at a time by construction, matching [DailySafetyMeetingRepository].
class MeetingAttendanceRepository {
  MeetingAttendanceRepository({
    required FirestoreService firestoreService,
    required String organizationId,
    required String meetingId,
  }) : _organizationId = organizationId,
       _meetingId = meetingId,
       _repository = FirestoreRepository<MeetingAttendance>(
         firestoreService: firestoreService,
         collectionPath: FirestorePaths.meetingAttendanceCollection(
           organizationId,
           meetingId,
         ),
         fromFirestore: MeetingAttendance.fromFirestore,
         toFirestore: (_) => throw UnsupportedError(
           'Meeting attendance records are written server-side.',
         ),
       );

  final String _organizationId;
  final String _meetingId;
  final FirestoreRepository<MeetingAttendance> _repository;

  /// Streams every attendance record for this meeting.
  Stream<List<MeetingAttendance>> watchAll() => _repository.watchCollection();

  Future<MeetingAttendance?> getByWorker(String workerId) =>
      _repository.getById(workerId);

  /// The organization this repository is scoped to.
  String get organizationId => _organizationId;

  /// The meeting this repository is scoped to.
  String get meetingId => _meetingId;
}
