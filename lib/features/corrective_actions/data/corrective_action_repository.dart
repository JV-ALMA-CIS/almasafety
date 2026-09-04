import '../../../core/constants/firestore_paths.dart';
import '../../../core/services/firestore_repository.dart';
import '../../../core/services/firestore_service.dart';
import '../domain/corrective_action.dart';

/// Reads corrective actions from
/// `organizations/{organizationId}/corrective_actions`.
///
/// Read-only — see [MeetingConcernRepository]'s doc comment for why
/// creating one and transitioning its status goes through a callable
/// instead ([CorrectiveActionService]). Scoped to one organization at a
/// time by construction, matching [DailySafetyMeetingRepository].
class CorrectiveActionRepository {
  CorrectiveActionRepository({
    required FirestoreService firestoreService,
    required String organizationId,
  }) : _organizationId = organizationId,
       _repository = FirestoreRepository<CorrectiveAction>(
         firestoreService: firestoreService,
         collectionPath: FirestorePaths.correctiveActionsCollection(
           organizationId,
         ),
         fromFirestore: CorrectiveAction.fromFirestore,
         toFirestore: (_) => throw UnsupportedError(
           'Corrective actions are written server-side.',
         ),
       );

  final String _organizationId;
  final FirestoreRepository<CorrectiveAction> _repository;

  Future<CorrectiveAction?> getById(String id) => _repository.getById(id);

  /// Streams every corrective action raised from one meeting — the meeting
  /// workspace's "corrective actions raised from this meeting" view.
  Stream<List<CorrectiveAction>> watchForMeeting(String meetingId) {
    return _repository.watchCollection(
      queryBuilder: (query) => query.where('meetingId', isEqualTo: meetingId),
    );
  }

  /// Streams every corrective action raised from one concern.
  Stream<List<CorrectiveAction>> watchForConcern(String concernId) {
    return _repository.watchCollection(
      queryBuilder: (query) =>
          query.where('concernId', isEqualTo: concernId),
    );
  }

  /// Streams every corrective action raised from one hazard — at most one is
  /// expected, since a hazard can be linked to only one corrective action
  /// (see `Hazard.correctiveActionId`), but this returns a list like every
  /// other `watchFor*` query here rather than special-casing the single-item
  /// case.
  Stream<List<CorrectiveAction>> watchForHazard(String hazardId) {
    return _repository.watchCollection(
      queryBuilder: (query) => query.where('hazardId', isEqualTo: hazardId),
    );
  }

  /// Streams every corrective action in this organization, across every
  /// site and meeting — the authorized supervisor/manager's Corrective
  /// Actions list.
  Stream<List<CorrectiveAction>> watchForOrganization() {
    return _repository.watchCollection();
  }

  /// The organization this repository is scoped to.
  String get organizationId => _organizationId;
}
