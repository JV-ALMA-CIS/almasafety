import 'dart:async';
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

  /// Streams exactly the given sites, by document id.
  ///
  /// Required for a caller whose `firestore.rules` read grant is scoped to
  /// specific site ids rather than "any site in this organization" — a
  /// Foreman may only read a site whose id is in their own membership's
  /// `siteIds` (see `firestore.rules`'s `sites/{siteId}` rule). Merges one
  /// [watchById] stream per id — mirroring
  /// [OrganizationRepository.watchByIds]'s exact pattern — rather than a
  /// single `whereIn` collection QUERY: "rules are not filters," so Cloud
  /// Firestore must prove a LIST query's rule safe using only the query's
  /// own constraints, and a rule branch built on `get()`ing the CALLER's
  /// own membership document (as this collection's site-scoped grant is)
  /// can never be proven that way, however the query itself is narrowed —
  /// Firestore rejects a `whereIn` query under that rule just as outright
  /// as an unconstrained [watchAll] would be. A per-document `get()` read
  /// (what [watchById] issues, and what `allow get` in `firestore.rules`
  /// grants) has no such limitation: the caller's own `siteIds` membership
  /// data is simply read fresh for that one document, each time.
  ///
  /// Emits an empty list immediately for an empty [siteIds] (rather than
  /// never emitting), and withholds every emission until all [siteIds] have
  /// reported at least once — see [OrganizationRepository.watchByIds]'s own
  /// doc comment for why.
  Stream<List<Site>> watchByIds(List<String> siteIds) {
    if (siteIds.isEmpty) return Stream.value(const []);

    final ids = List<String>.unmodifiable(siteIds);
    final latest = List<Site?>.filled(ids.length, null);
    final reported = List<bool>.filled(ids.length, false);
    final controller = StreamController<List<Site>>.broadcast();
    final subscriptions = <StreamSubscription<Site?>>[];

    void emit() {
      if (controller.isClosed) return;
      if (reported.any((done) => !done)) return;
      controller.add(latest.whereType<Site>().toList(growable: false));
    }

    for (var i = 0; i < ids.length; i++) {
      final index = i;
      subscriptions.add(
        watchById(ids[index]).listen((site) {
          latest[index] = site;
          reported[index] = true;
          emit();
        }, onError: controller.addError),
      );
    }

    controller.onCancel = () async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    };

    return controller.stream;
  }

  /// The organization this repository is scoped to.
  String get organizationId => _organizationId;
}
