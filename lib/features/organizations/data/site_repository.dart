import '../../../core/constants/firestore_paths.dart';
import '../../../core/services/firestore_repository.dart';
import '../../../core/services/firestore_service.dart';
import '../domain/site.dart';

/// Reads sites from `organizations/{organizationId}/sites`.
///
/// Read-only — see [OrganizationRepository]'s doc comment for why creating
/// and editing a site goes through a callable instead. Scoped to one
/// organization at a time by construction, matching [ProjectRepository].
class SiteRepository {
  SiteRepository({
    required FirestoreService firestoreService,
    required String organizationId,
  }) : _organizationId = organizationId,
       _repository = FirestoreRepository<Site>(
         firestoreService: firestoreService,
         collectionPath: FirestorePaths.sitesCollection(organizationId),
         fromFirestore: Site.fromFirestore,
         toFirestore: (_) =>
             throw UnsupportedError('Sites are written server-side.'),
       );

  final String _organizationId;
  final FirestoreRepository<Site> _repository;

  Future<Site?> getById(String id) => _repository.getById(id);

  Stream<Site?> watchById(String id) => _repository.watchById(id);

  /// Streams every site in this organization.
  Stream<List<Site>> watchAll() => _repository.watchCollection();

  /// Streams every site belonging to one project within this organization.
  ///
  /// A site is flat under the organization (`projectId` is a field, not a
  /// path segment — see [Site]'s doc comment), so narrowing to one project
  /// is a query, not a different collection path.
  Stream<List<Site>> watchByProject(String projectId) {
    return _repository.watchCollection(
      queryBuilder: (query) => query.where('projectId', isEqualTo: projectId),
    );
  }

  /// The organization this repository is scoped to.
  String get organizationId => _organizationId;
}
