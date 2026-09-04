import '../../../core/constants/firestore_paths.dart';
import '../../../core/services/firestore_repository.dart';
import '../../../core/services/firestore_service.dart';
import '../domain/project.dart';

/// Reads projects from `organizations/{organizationId}/projects`.
///
/// Read-only — see [OrganizationRepository]'s doc comment for why creating
/// and editing a project goes through a callable instead. Scoped to one
/// organization at a time by construction: there is no method that reads
/// across organizations, matching `firestore.rules`' `belongsToOrganization`
/// gate, which denies a client any read outside its own organization anyway.
class ProjectRepository {
  ProjectRepository({
    required FirestoreService firestoreService,
    required String organizationId,
  }) : _repository = FirestoreRepository<Project>(
         firestoreService: firestoreService,
         collectionPath: FirestorePaths.projectsCollection(organizationId),
         fromFirestore: Project.fromFirestore,
         toFirestore: (_) =>
             throw UnsupportedError('Projects are written server-side.'),
       );

  final FirestoreRepository<Project> _repository;

  Future<Project?> getById(String id) => _repository.getById(id);

  Stream<Project?> watchById(String id) => _repository.watchById(id);

  /// Streams every project in this organization.
  Stream<List<Project>> watchAll() => _repository.watchCollection();
}
