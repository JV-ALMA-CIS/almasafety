import '../../../core/constants/firestore_paths.dart';
import '../../../core/services/firestore_repository.dart';
import '../../../core/services/firestore_service.dart';
import '../domain/incident.dart';

/// Reads incidents from `organizations/{organizationId}/incidents`.
///
/// Read-only — every write goes through [IncidentService]'s callables.
/// `firestore.rules` admits a worker's read only for their own reports, so
/// a worker must use [watchReportedBy]; [watchForOrganization] is for
/// reviewer roles only.
class IncidentRepository {
  IncidentRepository({
    required FirestoreService firestoreService,
    required String organizationId,
  }) : _organizationId = organizationId,
       _repository = FirestoreRepository<Incident>(
         firestoreService: firestoreService,
         collectionPath: FirestorePaths.incidentsCollection(organizationId),
         fromFirestore: Incident.fromFirestore,
         toFirestore: (_) =>
             throw UnsupportedError('Incidents are written server-side.'),
       );

  final String _organizationId;
  final FirestoreRepository<Incident> _repository;

  Stream<Incident?> watchById(String id) => _repository.watchById(id);

  /// Streams every incident reported by [workerUid], most recent first.
  Stream<List<Incident>> watchReportedBy(String workerUid) {
    return _repository.watchCollection(
      queryBuilder: (query) => query
          .where('reportedByUid', isEqualTo: workerUid)
          .orderBy('createdAt', descending: true),
    );
  }

  /// Streams every incident in this organization, most recent first — a
  /// reviewer's view.
  Stream<List<Incident>> watchForOrganization() {
    return _repository.watchCollection(
      queryBuilder: (query) => query.orderBy('createdAt', descending: true),
    );
  }

  /// The organization this repository is scoped to.
  String get organizationId => _organizationId;
}
