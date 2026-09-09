import '../../../core/constants/firestore_paths.dart';
import '../../../core/services/firestore_repository.dart';
import '../../../core/services/firestore_service.dart';
import '../domain/meeting_point_note.dart';

/// Reads discussion notes for one Daily Safety Meeting from
/// `organizations/{organizationId}/daily_safety_meetings/{meetingId}/point_notes`.
///
/// Read-only — see [DailySafetyMeetingRepository]'s doc comment for why
/// creating and editing a note goes through a callable instead
/// ([DailySafetyMeetingService.setMeetingPointNote]). Scoped to one
/// organization and meeting at a time by construction, mirroring
/// [MeetingAttendanceRepository].
class MeetingPointNoteRepository {
  MeetingPointNoteRepository({
    required FirestoreService firestoreService,
    required String organizationId,
    required String meetingId,
  }) : _organizationId = organizationId,
       _meetingId = meetingId,
       _repository = FirestoreRepository<MeetingPointNote>(
         firestoreService: firestoreService,
         collectionPath: FirestorePaths.meetingPointNotesCollection(
           organizationId,
           meetingId,
         ),
         fromFirestore: MeetingPointNote.fromFirestore,
         toFirestore: (_) => throw UnsupportedError(
           'Meeting point notes are written server-side.',
         ),
       );

  final String _organizationId;
  final String _meetingId;
  final FirestoreRepository<MeetingPointNote> _repository;

  /// Streams every discussion note currently recorded for this meeting.
  Stream<List<MeetingPointNote>> watchAll() => _repository.watchCollection();

  /// The organization this repository is scoped to.
  String get organizationId => _organizationId;

  /// The meeting this repository is scoped to.
  String get meetingId => _meetingId;
}
