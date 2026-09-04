import '../../../core/constants/firestore_paths.dart';
import '../../../core/services/firestore_repository.dart';
import '../../../core/services/firestore_service.dart';
import '../domain/activity_assignment.dart';

/// Reads worker assignments for activities.
///
/// Read-only — see [ActivityRepository]'s doc comment for why creating and
/// removing an assignment goes through a callable instead
/// (`assignWorkerToActivity`/`removeWorkerFromActivity` in
/// `functions/src/activity_assignment_callable.ts`).
class ActivityAssignmentRepository {
  ActivityAssignmentRepository({
    required this._firestoreService,
    required this._organizationId,
  });

  final FirestoreService _firestoreService;
  final String _organizationId;

  /// Streams every worker assigned to one activity.
  Stream<List<ActivityAssignment>> watchAssignedWorkers(String activityId) {
    final repository = FirestoreRepository<ActivityAssignment>(
      firestoreService: _firestoreService,
      collectionPath: FirestorePaths.activityAssignmentsCollection(
        _organizationId,
        activityId,
      ),
      fromFirestore: ActivityAssignment.fromFirestore,
      toFirestore: (_) =>
          throw UnsupportedError('Assignments are written server-side.'),
    );
    return repository.watchCollection();
  }

  /// Streams every activity assignment held by [uid] within this
  /// organization, across all activities.
  ///
  /// Uses a Firestore collection-group query over the `assignments`
  /// subcollection, filtered to this organization and this worker. Backs
  /// the worker detail screen's "Assigned Activities" section. Requires the
  /// `assignments` collection-group composite index on
  /// (`organizationId`, `uid`) declared in `firestore.indexes.json`.
  Stream<List<ActivityAssignment>> watchAssignmentsForWorker(
    String organizationId,
    String uid,
  ) {
    final firestore = _firestoreService.require;
    return firestore
        .collectionGroup('assignments')
        .where('organizationId', isEqualTo: organizationId)
        .where('uid', isEqualTo: uid)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map(ActivityAssignment.fromFirestore)
              .toList(),
        );
  }

  /// The organization this repository is scoped to.
  String get organizationId => _organizationId;
}
