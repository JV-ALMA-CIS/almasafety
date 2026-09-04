import '../../../core/constants/firestore_paths.dart';
import '../../../core/services/firestore_repository.dart';
import '../../../core/services/firestore_service.dart';
import '../domain/safety_learning.dart';

/// Reads safety learning items from
/// `organizations/{organizationId}/safety_learning`.
///
/// Read-only — see [ActivityRepository]'s doc comment for why creating and
/// editing a safety learning item goes through a callable instead. Scoped
/// to one organization at a time by construction, matching
/// [ActivityRepository].
class SafetyLearningRepository {
  SafetyLearningRepository({
    required FirestoreService firestoreService,
    required String organizationId,
  }) : _organizationId = organizationId,
       _repository = FirestoreRepository<SafetyLearning>(
         firestoreService: firestoreService,
         collectionPath: FirestorePaths.safetyLearningCollection(
           organizationId,
         ),
         fromFirestore: SafetyLearning.fromFirestore,
         toFirestore: (_) => throw UnsupportedError(
           'Safety learning items are written server-side.',
         ),
       );

  final String _organizationId;
  final FirestoreRepository<SafetyLearning> _repository;

  Future<SafetyLearning?> getById(String id) => _repository.getById(id);

  Stream<SafetyLearning?> watchById(String id) => _repository.watchById(id);

  /// Streams every safety learning item in this organization.
  Stream<List<SafetyLearning>> watchAll() => _repository.watchCollection();

  /// The organization this repository is scoped to.
  String get organizationId => _organizationId;
}
