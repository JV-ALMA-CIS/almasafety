import '../../../core/constants/firestore_paths.dart';
import '../../../core/services/firestore_repository.dart';
import '../../../core/services/firestore_service.dart';
import '../domain/meeting_evidence.dart';

/// Reads evidence metadata for one Daily Safety Meeting from
/// `organizations/{organizationId}/daily_safety_meetings/{meetingId}/evidence`.
///
/// Read-only — see [DailySafetyMeetingRepository]'s doc comment for why
/// creating and editing an evidence record goes through a callable instead
/// ([DailySafetyMeetingService.uploadMeetingEvidence]). Scoped to one
/// organization and meeting at a time by construction, mirroring
/// [MeetingConcernRepository].
class MeetingEvidenceRepository {
  MeetingEvidenceRepository({
    required FirestoreService firestoreService,
    required String organizationId,
    required String meetingId,
  }) : _organizationId = organizationId,
       _meetingId = meetingId,
       _repository = FirestoreRepository<MeetingEvidence>(
         firestoreService: firestoreService,
         collectionPath: FirestorePaths.meetingEvidenceCollection(
           organizationId,
           meetingId,
         ),
         fromFirestore: MeetingEvidence.fromFirestore,
         toFirestore: (_) => throw UnsupportedError(
           'Meeting evidence records are written server-side.',
         ),
       );

  final String _organizationId;
  final String _meetingId;
  final FirestoreRepository<MeetingEvidence> _repository;

  /// Streams every piece of evidence currently recorded for this meeting.
  Stream<List<MeetingEvidence>> watchAll() => _repository.watchCollection();

  /// The organization this repository is scoped to.
  String get organizationId => _organizationId;

  /// The meeting this repository is scoped to.
  String get meetingId => _meetingId;
}
