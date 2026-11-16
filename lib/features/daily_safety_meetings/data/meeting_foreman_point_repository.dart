import '../../../core/constants/firestore_paths.dart';
import '../../../core/services/firestore_repository.dart';
import '../../../core/services/firestore_service.dart';
import '../domain/meeting_foreman_point.dart';

/// Reads the Foreman's own points for one Daily Safety Meeting from
/// `organizations/{organizationId}/daily_safety_meetings/{meetingId}/foreman_points`.
///
/// Read-only — writes go through
/// [DailySafetyMeetingService.saveMeetingForemanPoint]. Mirrors
/// [MeetingPointNoteRepository].
class MeetingForemanPointRepository {
  MeetingForemanPointRepository({
    required FirestoreService firestoreService,
    required String organizationId,
    required String meetingId,
  }) : _repository = FirestoreRepository<MeetingForemanPoint>(
         firestoreService: firestoreService,
         collectionPath: FirestorePaths.meetingForemanPointsCollection(
           organizationId,
           meetingId,
         ),
         fromFirestore: MeetingForemanPoint.fromFirestore,
         toFirestore: (_) => throw UnsupportedError(
           "The Foreman's meeting points are written server-side.",
         ),
       );

  final FirestoreRepository<MeetingForemanPoint> _repository;

  /// Streams every point the Foreman typed for this meeting, oldest first.
  Stream<List<MeetingForemanPoint>> watchAll() =>
      _repository.watchCollection().map(
        (points) => [...points]
          ..sort(
            (a, b) => (a.createdAt ?? DateTime(9999)).compareTo(
              b.createdAt ?? DateTime(9999),
            ),
          ),
      );
}
