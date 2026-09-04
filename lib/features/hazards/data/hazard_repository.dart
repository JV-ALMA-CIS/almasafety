import '../../../core/constants/firestore_paths.dart';
import '../../../core/services/firestore_repository.dart';
import '../../../core/services/firestore_service.dart';
import '../domain/hazard.dart';

/// Reads hazards from `organizations/{organizationId}/hazards`.
///
/// Read-only — see [CorrectiveActionRepository]'s doc comment for why
/// creating and transitioning one goes through a callable instead
/// ([HazardService]). Scoped to one organization at a time by construction,
/// matching [CorrectiveActionRepository].
class HazardRepository {
  HazardRepository({
    required FirestoreService firestoreService,
    required String organizationId,
  }) : _organizationId = organizationId,
       _repository = FirestoreRepository<Hazard>(
         firestoreService: firestoreService,
         collectionPath: FirestorePaths.hazardsCollection(organizationId),
         fromFirestore: Hazard.fromFirestore,
         toFirestore: (_) =>
             throw UnsupportedError('Hazards are written server-side.'),
       );

  final String _organizationId;
  final FirestoreRepository<Hazard> _repository;

  Future<Hazard?> getById(String id) => _repository.getById(id);

  Stream<Hazard?> watchById(String id) => _repository.watchById(id);

  /// Streams every hazard reported by [workerUid] — the worker's own "My
  /// Reports" view, most recent first.
  Stream<List<Hazard>> watchReportedBy(String workerUid) {
    return _repository.watchCollection(
      queryBuilder: (query) => query
          .where('reportedByUid', isEqualTo: workerUid)
          .orderBy('createdAt', descending: true),
    );
  }

  /// Streams every hazard for one site, most recent first — a site-scoped
  /// safety view (e.g. a foreman or supervisor's own site).
  Stream<List<Hazard>> watchForSite(String siteId) {
    return _repository.watchCollection(
      queryBuilder: (query) => query
          .where('siteId', isEqualTo: siteId)
          .orderBy('createdAt', descending: true),
    );
  }

  /// Streams every hazard in this organization, most recent first — an
  /// authorized reviewer's organization-wide Hazards list.
  Stream<List<Hazard>> watchForOrganization() {
    return _repository.watchCollection(
      queryBuilder: (query) => query.orderBy('createdAt', descending: true),
    );
  }

  /// The organization this repository is scoped to.
  String get organizationId => _organizationId;
}
