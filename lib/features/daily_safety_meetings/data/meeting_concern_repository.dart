import '../../../core/constants/firestore_paths.dart';
import '../../../core/services/firestore_repository.dart';
import '../../../core/services/firestore_service.dart';
import '../domain/meeting_concern.dart';

/// Reads concern records for one Daily Safety Meeting from
/// `organizations/{organizationId}/daily_safety_meetings/{meetingId}/concerns`.
///
/// Read-only — see [MeetingAttendanceRepository]'s doc comment for why
/// adding, editing and removing a concern goes through a callable instead
/// ([MeetingConcernService]). Scoped to one organization and meeting at a
/// time by construction, matching [MeetingAttendanceRepository].
class MeetingConcernRepository {
  MeetingConcernRepository({
    required FirestoreService firestoreService,
    required String organizationId,
    required String meetingId,
  }) : _organizationId = organizationId,
       _meetingId = meetingId,
       _repository = FirestoreRepository<MeetingConcern>(
         firestoreService: firestoreService,
         collectionPath: FirestorePaths.meetingConcernsCollection(
           organizationId,
           meetingId,
         ),
         fromFirestore: MeetingConcern.fromFirestore,
         toFirestore: (_) => throw UnsupportedError(
           'Meeting concerns are written server-side.',
         ),
       );

  final String _organizationId;
  final String _meetingId;
  final FirestoreRepository<MeetingConcern> _repository;

  /// Streams every concern recorded for this meeting.
  Stream<List<MeetingConcern>> watchAll() => _repository.watchCollection();

  /// The organization this repository is scoped to.
  String get organizationId => _organizationId;

  /// The meeting this repository is scoped to.
  String get meetingId => _meetingId;
}
