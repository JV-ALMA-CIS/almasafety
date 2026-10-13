import '../../../core/constants/firestore_paths.dart';
import '../../../core/services/firestore_repository.dart';
import '../../../core/services/firestore_service.dart';
import '../domain/app_notification.dart';

/// Reads notifications from `organizations/{organizationId}/notifications`.
///
/// Read-only — see [SafetyAlertRepository]'s doc comment for why creating
/// one and marking it read goes through a callable instead
/// ([NotificationService]). Scoped to one organization at a time by
/// construction, matching [SafetyAlertRepository]. Every query method here
/// takes the caller's own uid explicitly rather than assuming "current
/// user," mirroring [WorkerLearningRepository.watchMine] — the
/// organization-isolation and user-isolation boundaries that actually
/// matter are enforced server-side by `firestore.rules`
/// (`recipientUid == request.auth.uid`), not by this class trusting its own
/// query filter.
class NotificationRepository {
  NotificationRepository({
    required FirestoreService firestoreService,
    required String organizationId,
  }) : _organizationId = organizationId,
       _repository = FirestoreRepository<AppNotification>(
         firestoreService: firestoreService,
         collectionPath: FirestorePaths.notificationsCollection(organizationId),
         fromFirestore: AppNotification.fromFirestore,
         toFirestore: (_) =>
             throw UnsupportedError('Notifications are written server-side.'),
       );

  final String _organizationId;
  final FirestoreRepository<AppNotification> _repository;

  Future<AppNotification?> getById(String id) => _repository.getById(id);

  /// Streams every notification addressed to [recipientUid] within this
  /// organization, most recent first — the signed-in user's own
  /// notification list. `firestore.rules` independently confirms
  /// `recipientUid == request.auth.uid` before returning any document, so
  /// passing another user's uid here yields a permission-denied stream
  /// error rather than that user's notifications.
  Stream<List<AppNotification>> watchForRecipient(String recipientUid) {
    return _repository.watchCollection(
      queryBuilder: (query) => query
          .where('recipientUid', isEqualTo: recipientUid)
          .orderBy('createdAt', descending: true),
    );
  }

  /// Streams only the unread notifications addressed to [recipientUid] —
  /// backs the unread-count badge without requiring the full list to be
  /// loaded and filtered client-side.
  Stream<List<AppNotification>> watchUnreadForRecipient(String recipientUid) {
    return _repository.watchCollection(
      queryBuilder: (query) => query
          .where('recipientUid', isEqualTo: recipientUid)
          .where('isRead', isEqualTo: false),
    );
  }

  /// The organization this repository is scoped to.
  String get organizationId => _organizationId;
}
