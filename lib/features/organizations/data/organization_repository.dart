import 'dart:async';
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
  /// Readable only by a System Administrator. `firestore.rules`' `allow
  /// read` on `organizations/{organizationId}` only ever grants a per-
  /// document read (`belongsToOrganization(organizationId)` cannot be
  /// proven for every document an unconstrained COLLECTION LIST could
  /// return) — Firestore denies a `list`/collection-query outright for
  /// anyone but Admin, who additionally has `isAdmin()` granting every
  /// document. A non-Admin caller must use [watchByIds] instead, scoped to
  /// the organization ids their own memberships name.
  Stream<List<Organization>> watchAll() => _repository.watchCollection();

  /// Streams the organizations named by [organizationIds] — one per-document
  /// watch per id, merged into a single list stream that re-emits whenever
  /// any of them changes.
  ///
  /// This is the correct way for a non-Admin (Site Manager, Foreman, ...) to
  /// see "my organizations": each id comes from that user's own
  /// `SessionController.memberships` (self-scoped, always readable), and
  /// each individual `organizations/{id}` read is permitted by
  /// `belongsToOrganization` — unlike [watchAll], which is a collection
  /// LIST query the rules structurally cannot permit for anyone but Admin.
  ///
  /// Emits an empty list immediately for an empty [organizationIds] (rather
  /// than never emitting), so a caller with zero memberships sees a settled,
  /// empty result instead of an indefinitely "loading" stream.
  ///
  /// Withholds every emission until all [organizationIds] have reported at
  /// least once — each underlying per-document watch resolves independently
  /// and at its own pace, so emitting as soon as the FIRST one arrives would
  /// let a consumer briefly see a partial, misleadingly-incomplete list
  /// (e.g. one organization flashing in alone before the rest catch up).
  Stream<List<Organization>> watchByIds(List<String> organizationIds) {
    if (organizationIds.isEmpty) return Stream.value(const []);

    final ids = List<String>.unmodifiable(organizationIds);
    final latest = List<Organization?>.filled(ids.length, null);
    final reported = List<bool>.filled(ids.length, false);
    final controller = StreamController<List<Organization>>.broadcast();
    final subscriptions = <StreamSubscription<Organization?>>[];

    void emit() {
      if (controller.isClosed) return;
      if (reported.any((done) => !done)) return;
      controller.add(
        latest.whereType<Organization>().toList(growable: false),
      );
    }

    for (var i = 0; i < ids.length; i++) {
      final index = i;
      subscriptions.add(
        watchById(ids[index]).listen(
          (organization) {
            latest[index] = organization;
            reported[index] = true;
            emit();
          },
          onError: controller.addError,
        ),
      );
    }

    controller.onCancel = () async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    };

    return controller.stream;
  }
}
