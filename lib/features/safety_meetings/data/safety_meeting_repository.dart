import '../../../core/constants/firestore_paths.dart';
import '../../../core/services/firestore_repository.dart';
import '../../../core/services/firestore_service.dart';
import '../domain/safety_meeting.dart';

/// Reads the weekly employee and monthly supervisory safety meetings of one
/// organization. Read-only: meetings are recorded through
/// [SafetyMeetingService].
class SafetyMeetingRepository {
  SafetyMeetingRepository({
    required FirestoreService firestoreService,
    required String organizationId,
  }) : _organizationId = organizationId,
       _meetings = FirestoreRepository<SafetyMeeting>(
         firestoreService: firestoreService,
         collectionPath: FirestorePaths.safetyMeetingsCollection(
           organizationId,
         ),
         fromFirestore: SafetyMeeting.fromFirestore,
         toFirestore: (_) =>
             throw UnsupportedError('Safety meetings are written server-side.'),
       );

  final String _organizationId;
  final FirestoreRepository<SafetyMeeting> _meetings;

  String get organizationId => _organizationId;

  /// Every meeting, most recent first.
  Stream<List<SafetyMeeting>> watchMeetings() => _meetings.watchCollection(
    queryBuilder: (query) => query.orderBy('date', descending: true),
  );
}
