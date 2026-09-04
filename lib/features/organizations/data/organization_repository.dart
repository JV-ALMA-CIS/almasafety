import '../../../core/constants/firestore_paths.dart';
import '../../../core/services/firestore_repository.dart';
import '../../../core/services/firestore_service.dart';
import '../domain/organization.dart';

/// Reads organizations from `organizations/{id}`.
///
/// Read-only by design: creating and editing an organization is a
/// privileged operation that goes through the `createOrganization` /
/// `updateOrganization` Cloud Functions callables
/// (`OrganizationAdminService`), never through this repository — mirroring
/// why `UserProfileRepository` has no method that writes `accountStatus`.
/// `firestore.rules` independently denies every client write to this
/// collection regardless.
class OrganizationRepository {
  OrganizationRepository({required FirestoreService firestoreService})
    : _repository = FirestoreRepository<Organization>(
        firestoreService: firestoreService,
        collectionPath: FirestorePaths.organizations,
        fromFirestore: Organization.fromFirestore,
        toFirestore: (_) =>
            throw UnsupportedError('Organizations are written server-side.'),
      );

  final FirestoreRepository<Organization> _repository;

  Future<Organization?> getById(String id) => _repository.getById(id);

  Stream<Organization?> watchById(String id) => _repository.watchById(id);

  /// Streams every organization.
  ///
  /// Readable only by a System Administrator — `firestore.rules` denies an
  /// ordinary org member a read of any organization document other than
  /// their own (`belongsToOrganization`), so this stream returns nothing for
  /// anyone else, consistent with the client never being the security
  /// boundary.
  Stream<List<Organization>> watchAll() => _repository.watchCollection();
}
