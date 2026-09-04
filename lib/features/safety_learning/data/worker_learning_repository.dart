import '../../../core/constants/firestore_paths.dart';
import '../../../core/services/firestore_repository.dart';
import '../../../core/services/firestore_service.dart';
import '../domain/worker_learning_record.dart';

/// Reads worker learning records from
/// `organizations/{organizationId}/worker_learning_records`.
///
/// Read-only — see [ActivityAssignmentRepository]'s doc comment for why
/// creating and transitioning a record goes through a callable instead
/// ([WorkerLearningService]). Scoped to one organization at a time by
/// construction, matching [ActivityRepository].
class WorkerLearningRepository {
  WorkerLearningRepository({
    required FirestoreService firestoreService,
    required String organizationId,
  }) : _organizationId = organizationId,
       _repository = FirestoreRepository<WorkerLearningRecord>(
         firestoreService: firestoreService,
         collectionPath: FirestorePaths.workerLearningRecordsCollection(
           organizationId,
         ),
         fromFirestore: WorkerLearningRecord.fromFirestore,
         toFirestore: (_) => throw UnsupportedError(
           'Worker learning records are written server-side.',
         ),
       );

  final String _organizationId;
  final FirestoreRepository<WorkerLearningRecord> _repository;

  /// Streams the learning records belonging to one worker within this
  /// organization — the worker's own "My Safety Learning" view.
  Stream<List<WorkerLearningRecord>> watchMine(String workerUid) {
    return _repository.watchCollection(
      queryBuilder: (query) => query.where('workerUid', isEqualTo: workerUid),
    );
  }

  /// Streams every learning record in this organization — the admin
  /// compliance view.
  Stream<List<WorkerLearningRecord>> watchForOrganization() {
    return _repository.watchCollection();
  }

  /// The organization this repository is scoped to.
  String get organizationId => _organizationId;
}
