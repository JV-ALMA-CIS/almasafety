import '../../../core/constants/firestore_paths.dart';
import '../../../core/services/firestore_repository.dart';
import '../../../core/services/firestore_service.dart';
import '../../organizations/domain/organization_record_status.dart';
import '../../safety_learning/data/safety_learning_repository.dart';
import '../../safety_learning/domain/safety_learning.dart';
import '../domain/safety_requirement.dart';

/// Reads safety requirements from
/// `organizations/{organizationId}/safety_requirements`, and resolves the
/// required-learning set they imply.
///
/// Read-only — see [ActivityRepository]'s doc comment for why creating and
/// editing a safety requirement goes through a callable instead. Scoped to
/// one organization at a time by construction, matching [ActivityRepository].
///
/// **Required-learning resolution — the "assignment principle" foundation.**
/// This stage does not implement full automatic
/// Worker -> Role -> Site -> Activity -> Risk -> Requirement resolution.
/// Instead, a [SafetyRequirement] applies organization-wide: a worker's
/// required learning is the union of `requiredLearningIds` across every
/// ACTIVE [SafetyRequirement] in their organization, resolved to ACTIVE
/// [SafetyLearning] items only (an inactive learning item does not drive a
/// new obligation, even if a requirement still lists its id — mirroring how
/// inactive Sites/Activities still exist but don't drive new obligations).
///
/// Deliberately kept in this ONE method so a later stage can narrow it (e.g.
/// by adding optional `siteIds`/`activityIds`/`roles` scoping fields to
/// [SafetyRequirement] and filtering here) without that logic being
/// duplicated or hardcoded anywhere else — every caller (the worker's own
/// view and the admin compliance view) goes through
/// `resolveRequiredLearning`, on the client, and through the equivalent
/// server-side logic in `getMyRequiredLearning`
/// (`functions/src/worker_learning_callable.ts`), which re-derives this same
/// set — never trusting a client-supplied "this is required" claim.
class SafetyRequirementRepository {
  SafetyRequirementRepository({
    required FirestoreService firestoreService,
    required String organizationId,
    SafetyLearningRepository? safetyLearningRepository,
  }) : _organizationId = organizationId,
       _repository = FirestoreRepository<SafetyRequirement>(
         firestoreService: firestoreService,
         collectionPath: FirestorePaths.safetyRequirementsCollection(
           organizationId,
         ),
         fromFirestore: SafetyRequirement.fromFirestore,
         toFirestore: (_) => throw UnsupportedError(
           'Safety requirements are written server-side.',
         ),
       ),
       _safetyLearningRepository = safetyLearningRepository ??
           SafetyLearningRepository(
             firestoreService: firestoreService,
             organizationId: organizationId,
           );

  final String _organizationId;
  final FirestoreRepository<SafetyRequirement> _repository;
  final SafetyLearningRepository _safetyLearningRepository;

  Future<SafetyRequirement?> getById(String id) => _repository.getById(id);

  Stream<SafetyRequirement?> watchById(String id) =>
      _repository.watchById(id);

  /// Streams every safety requirement in this organization.
  Stream<List<SafetyRequirement>> watchAll() => _repository.watchCollection();

  /// The de-duplicated, ACTIVE [SafetyLearning] items required across every
  /// ACTIVE [SafetyRequirement] in this organization.
  ///
  /// See this class's doc comment for the resolution rule.
  Stream<List<SafetyLearning>> watchResolvedRequiredLearning() {
    return watchAll().asyncMap((requirements) async {
      final requiredIds = <String>{
        for (final requirement in requirements)
          if (requirement.status == OrganizationRecordStatus.active)
            ...requirement.requiredLearningIds,
      };
      final learningItems = await _safetyLearningRepository.watchAll().first;
      final learningById = {
        for (final item in learningItems) item.id: item,
      };
      return [
        for (final id in requiredIds)
          if (learningById[id] != null &&
              learningById[id]!.status == OrganizationRecordStatus.active)
            learningById[id]!,
      ];
    });
  }

  /// The organization this repository is scoped to.
  String get organizationId => _organizationId;
}
