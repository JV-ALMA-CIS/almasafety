import '../../../core/constants/firestore_paths.dart';
import '../../../core/services/firestore_repository.dart';
import '../../../core/services/firestore_service.dart';
import '../domain/safety_alert.dart';

/// Reads safety alerts from
/// `organizations/{organizationId}/safety_alerts`.
///
/// Read-only — see [CorrectiveActionRepository]'s doc comment for why
/// creating one and transitioning its status goes through a callable
/// instead ([SafetyAlertService]). Scoped to one organization at a time by
/// construction, matching [CorrectiveActionRepository].
class SafetyAlertRepository {
  SafetyAlertRepository({
    required FirestoreService firestoreService,
    required String organizationId,
  }) : _organizationId = organizationId,
       _repository = FirestoreRepository<SafetyAlert>(
         firestoreService: firestoreService,
         collectionPath: FirestorePaths.safetyAlertsCollection(organizationId),
         fromFirestore: SafetyAlert.fromFirestore,
         toFirestore: (_) =>
             throw UnsupportedError('Safety alerts are written server-side.'),
       );

  final String _organizationId;
  final FirestoreRepository<SafetyAlert> _repository;

  Future<SafetyAlert?> getById(String id) => _repository.getById(id);

  /// Streams every safety alert in this organization, across every site —
  /// the authorized user's Safety Alerts screen.
  Stream<List<SafetyAlert>> watchForOrganization() =>
      _repository.watchCollection();

  /// Streams every safety alert for one site within this organization — a
  /// worker/foreman's "alerts applicable to my site" view.
  Stream<List<SafetyAlert>> watchForSite(String siteId) {
    return _repository.watchCollection(
      queryBuilder: (query) => query.where('siteId', isEqualTo: siteId),
    );
  }

  /// The organization this repository is scoped to.
  String get organizationId => _organizationId;
}
